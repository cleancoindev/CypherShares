/*
    Copyright 2020 Set Labs Inc.
    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at
    http://www.apache.org/licenses/LICENSE-2.0
    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
    SPDX-License-Identifier: Apache License, Version 2.0
*/

pragma solidity 0.7.5;
pragma experimental "ABIEncoderV2";

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/SafeCast.sol";
import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { SignedSafeMath } from "@openzeppelin/contracts/math/SignedSafeMath.sol";

import { IController } from "../../interfaces/IController.sol";
import { ICSToken } from "../../interfaces/ICSToken.sol";
import { ModuleBase } from "../lib/ModuleBase.sol";
import { PreciseUnitMath } from "../../lib/PreciseUnitMath.sol";


/**
 * @title StreamingFeeModule
 * @author Set Protocol
 *
 * Smart contract that accrues streaming fees for Set managers. Streaming fees are denominated as percent
 * per year and realized as Set inflation rewarded to the manager.
 */
contract StreamingFeeModule is ModuleBase, ReentrancyGuard {
    using SafeMath for uint256;
    using PreciseUnitMath for uint256;
    using SafeCast for uint256;

    using SignedSafeMath for int256;
    using PreciseUnitMath for int256;
    using SafeCast for int256;


    /* ============ Structs ============ */

    struct FeeState {
        address feeRecipient;                   // Address to accrue fees to
        uint256 maxStreamingFeePercentage;      // Max streaming fee maanager commits to using (1% = 1e16, 100% = 1e18)
        uint256 streamingFeePercentage;         // Percent of Set accruing to manager annually (1% = 1e16, 100% = 1e18)
        uint256 lastStreamingFeeTimestamp;      // Timestamp last streaming fee was accrued
    }

    /* ============ Events ============ */

    event FeeActualized(address indexed _csToken, uint256 _managerFee, uint256 _protocolFee);
    event StreamingFeeUpdated(address indexed _csToken, uint256 _newStreamingFee);
    event FeeRecipientUpdated(address indexed _csToken, address _newFeeRecipient);

    /* ============ Constants ============ */

    uint256 private constant ONE_YEAR_IN_SECONDS = 365.25 days;
    uint256 private constant PROTOCOL_STREAMING_FEE_INDEX = 0;

    /* ============ State Variables ============ */

    mapping(ICSToken => FeeState) public feeStates;

    /* ============ Constructor ============ */

    constructor(IController _controller) ModuleBase(_controller) {}

    /* ============ External Functions ============ */

    /*
     * Calculates total inflation percentage then mints new Sets to the fee recipient. Position units are
     * then adjusted down (in magnitude) in order to ensure full collateralization. Callable by anyone.
     *
     * @param _csToken       Address of CSToken
     */
    function accrueFee(ICSToken _csToken) public nonReentrant onlyValidAndInitializedSet(_csToken) {
        uint256 managerFee;
        uint256 protocolFee;

        if (_streamingFeePercentage(_csToken) > 0) {
            uint256 inflationFeePercentage = _calculateStreamingFee(_csToken);

            // Calculate incentiveFee inflation
            uint256 feeQuantity = _calculateStreamingFeeInflation(_csToken, inflationFeePercentage);

            // Mint new Sets to manager and protocol
            (
                managerFee,
                protocolFee
            ) = _mintManagerAndProtocolFee(_csToken, feeQuantity);

            _editPositionMultiplier(_csToken, inflationFeePercentage);
        }

        feeStates[_csToken].lastStreamingFeeTimestamp = block.timestamp;

        emit FeeActualized(address(_csToken), managerFee, protocolFee);
    }

    /**
     * SET MANAGER ONLY. Initialize module with CSToken and set the fee state for the CSToken. Passed
     * _settings will have lastStreamingFeeTimestamp over-written.
     *
     * @param _csToken                 Address of CSToken
     * @param _settings                 FeeState struct defining fee parameters
     */
    function initialize(
        ICSToken _csToken,
        FeeState memory _settings
    )
        external
        onlySetManager(_csToken, msg.sender)
        onlyValidAndPendingSet(_csToken)
    {
        require(_settings.feeRecipient != address(0), "Fee Recipient must be non-zero address.");
        require(_settings.maxStreamingFeePercentage < PreciseUnitMath.preciseUnit(), "Max fee must be < 100%.");
        require(_settings.streamingFeePercentage <= _settings.maxStreamingFeePercentage, "Fee must be <= max.");

        _settings.lastStreamingFeeTimestamp = block.timestamp;

        feeStates[_csToken] = _settings;
        _csToken.initializeModule();
    }

    /**
     * Removes this module from the CSToken, via call by the CSToken. Manager's feeState is deleted. Fees
     * are not accrued in case reason for removing module is related to fee accrual.
     */
    function removeModule() external override {
        delete feeStates[ICSToken(msg.sender)];
    }

    /*
     * Set new streaming fee. Fees accrue at current rate then new rate is set.
     * Fees are accrued to prevent the manager from unfairly accruing a larger percentage.
     *
     * @param _csToken       Address of CSToken
     * @param _newFee         New streaming fee 18 decimal precision
     */
    function updateStreamingFee(
        ICSToken _csToken,
        uint256 _newFee
    )
        external
        onlySetManager(_csToken, msg.sender)
        onlyValidAndInitializedSet(_csToken)
    {
        require(_newFee < _maxStreamingFeePercentage(_csToken), "Fee must be less than max");
        accrueFee(_csToken);

        feeStates[_csToken].streamingFeePercentage = _newFee;

        emit StreamingFeeUpdated(address(_csToken), _newFee);
    }

    /*
     * Set new fee recipient.
     *
     * @param _csToken             Address of CSToken
     * @param _newFeeRecipient      New fee recipient
     */
    function updateFeeRecipient(ICSToken _csToken, address _newFeeRecipient)
        external
        onlySetManager(_csToken, msg.sender)
        onlyValidAndInitializedSet(_csToken)
    {
        require(_newFeeRecipient != address(0), "Fee Recipient must be non-zero address.");

        feeStates[_csToken].feeRecipient = _newFeeRecipient;

        emit FeeRecipientUpdated(address(_csToken), _newFeeRecipient);
    }

    /*
     * Calculates total inflation percentage in order to accrue fees to manager.
     *
     * @param _csToken       Address of CSToken
     * @return  uint256       Percent inflation of supply
     */
    function getFee(ICSToken _csToken) external view returns (uint256) {
        return _calculateStreamingFee(_csToken);
    }

    /* ============ Internal Functions ============ */

    /**
     * Calculates streaming fee by multiplying streamingFeePercentage by the elapsed amount of time since the last fee
     * was collected divided by one year in seconds, since the fee is a yearly fee.
     *
     * @param  _csToken          Address of Set to have feeState updated
     * @return uint256            Streaming fee denominated in percentage of totalSupply
     */
    function _calculateStreamingFee(ICSToken _csToken) internal view returns(uint256) {
        uint256 timeSinceLastFee = block.timestamp.sub(_lastStreamingFeeTimestamp(_csToken));

        // Streaming fee is streaming fee times years since last fee
        return timeSinceLastFee.mul(_streamingFeePercentage(_csToken)).div(ONE_YEAR_IN_SECONDS);
    }

    /**
     * Returns the new incentive fee denominated in the number of CSTokens to mint. The calculation for the fee involves
     * implying mint quantity so that the feeRecipient owns the fee percentage of the entire supply of the Set.
     *
     * The formula to solve for fee is:
     * (feeQuantity / feeQuantity) + totalSupply = fee / scaleFactor
     *
     * The simplified formula utilized below is:
     * feeQuantity = fee * totalSupply / (scaleFactor - fee)
     *
     * @param   _csToken               CSToken instance
     * @param   _feePercentage          Fee levied to feeRecipient
     * @return  uint256                 New RebalancingSet issue quantity
     */
    function _calculateStreamingFeeInflation(
        ICSToken _csToken,
        uint256 _feePercentage
    )
        internal
        view
        returns (uint256)
    {
        uint256 totalSupply = _csToken.totalSupply();

        // fee * totalSupply
        uint256 a = _feePercentage.mul(totalSupply);

        // ScaleFactor (10e18) - fee
        uint256 b = PreciseUnitMath.preciseUnit().sub(_feePercentage);

        return a.div(b);
    }

    /**
     * Mints sets to both the manager and the protocol. Protocol takes a percentage fee of the total amount of Sets
     * minted to manager.
     *
     * @param   _csToken               CSToken instance
     * @param   _feeQuantity            Amount of Sets to be minted as fees
     * @return  uint256                 Amount of Sets accrued to manager as fee
     * @return  uint256                 Amount of Sets accrued to protocol as fee
     */
    function _mintManagerAndProtocolFee(ICSToken _csToken, uint256 _feeQuantity) internal returns (uint256, uint256) {
        address protocolFeeRecipient = controller.feeRecipient();
        uint256 protocolFee = controller.getModuleFee(address(this), PROTOCOL_STREAMING_FEE_INDEX);

        uint256 protocolFeeAmount = _feeQuantity.preciseMul(protocolFee);
        uint256 managerFeeAmount = _feeQuantity.sub(protocolFeeAmount);

        _csToken.mint(_feeRecipient(_csToken), managerFeeAmount);

        if (protocolFeeAmount > 0) {
            _csToken.mint(protocolFeeRecipient, protocolFeeAmount);
        }

        return (managerFeeAmount, protocolFeeAmount);
    }

    /**
     * Calculates new position multiplier according to following formula:
     *
     * newMultiplier = oldMultiplier * (1-inflationFee)
     *
     * This reduces position sizes to offset increase in supply due to fee collection.
     *
     * @param   _csToken               CSToken instance
     * @param   _inflationFee           Fee inflation rate
     */
    function _editPositionMultiplier(ICSToken _csToken, uint256 _inflationFee) internal {
        int256 currentMultipler = _csToken.positionMultiplier();
        int256 newMultiplier = currentMultipler.preciseMul(PreciseUnitMath.preciseUnit().sub(_inflationFee).toInt256());

        _csToken.editPositionMultiplier(newMultiplier);
    }

    function _feeRecipient(ICSToken _set) internal view returns (address) {
        return feeStates[_set].feeRecipient;
    }

    function _lastStreamingFeeTimestamp(ICSToken _set) internal view returns (uint256) {
        return feeStates[_set].lastStreamingFeeTimestamp;
    }

    function _maxStreamingFeePercentage(ICSToken _set) internal view returns (uint256) {
        return feeStates[_set].maxStreamingFeePercentage;
    }

    function _streamingFeePercentage(ICSToken _set) internal view returns (uint256) {
        return feeStates[_set].streamingFeePercentage;
    }
}