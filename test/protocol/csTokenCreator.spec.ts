import "module-alias/register";
import { BigNumber } from "@ethersproject/bignumber";

import { Account, Address } from "@utils/types";
import { ADDRESS_ZERO, ZERO, ONE } from "@utils/constants";
import { Controller, CSTokenCreator, StandardTokenMock } from "@utils/contracts";
import DeployHelper from "@utils/deploys";
import {
    addSnapshotBeforeRestoreAfterEach,
    ether,
    getAccounts,
    getProtocolUtils,
    getRandomAddress,
    getWaffleExpect,
} from "@utils/index";

const expect = getWaffleExpect();
const protocolUtils = getProtocolUtils();

describe("CSTokenCreator", () => {
    let owner: Account;
    let manager: Account;
    let controllerAddress: Account;

    let deployer: DeployHelper;

    before(async () => {
        [
            owner,
            manager,
            controllerAddress,
        ] = await getAccounts();

        deployer = new DeployHelper(owner.wallet);
    });

    addSnapshotBeforeRestoreAfterEach();

    describe("constructor", async () => {
        let subjectControllerAddress: Address;

        beforeEach(async () => {
            subjectControllerAddress = controllerAddress.address;
        });

        async function subject(): Promise<CSTokenCreator> {
            return await deployer.core.deployCSTokenCreator(
                subjectControllerAddress
            );
        }

        it("should have the correct controller", async () => {
            const newCSTokenCreator = await subject();

            const expectedController = await newCSTokenCreator.controller();
            expect(expectedController).to.eq(subjectControllerAddress);
        });
    });

    context("when there is a CSTokenCreator", async () => {
        let controller: Controller;
        let setTokenCreator: CSTokenCreator;

        beforeEach(async () => {
            controller = await deployer.core.deployController(owner.address);
            setTokenCreator = await deployer.core.deployCSTokenCreator(controller.address);

            await controller.initialize([setTokenCreator.address], [], [], []);
        });

        describe("#create", async () => {
            let firstComponent: StandardTokenMock;
            let secondComponent: StandardTokenMock;
            let firstModule: Address;
            let secondModule: Address;

            let subjectComponents: Address[];
            let subjectUnits: BigNumber[];
            let subjectModules: Address[];
            let subjectManager: Address;
            let subjectName: string;
            let subjectSymbol: string;

            beforeEach(async () => {
                firstComponent = await deployer.mocks.deployTokenMock(manager.address);
                secondComponent = await deployer.mocks.deployTokenMock(manager.address);
                firstModule = await getRandomAddress();
                secondModule = await getRandomAddress();

                await controller.addModule(firstModule);
                await controller.addModule(secondModule);

                subjectComponents = [firstComponent.address, secondComponent.address];
                subjectUnits = [ether(1), ether(2)];
                subjectModules = [firstModule, secondModule];
                subjectManager = await getRandomAddress();
                subjectName = "TestCSTokenCreator";
                subjectSymbol = "SET";
            });

            async function subject(): Promise<any> {
                return setTokenCreator.create(
                    subjectComponents,
                    subjectUnits,
                    subjectModules,
                    subjectManager,
                    subjectName,
                    subjectSymbol,
                );
            }

            it("should properly create the Set", async () => {
                const receipt = await subject();

                const address = await protocolUtils.getCreatedCSTokenAddress(receipt.hash);
                expect(address).to.be.properAddress;
            });

            it("should enable the Set on the controller", async () => {
                const receipt = await subject();

                const retrievedSetAddress = await protocolUtils.getCreatedCSTokenAddress(receipt.hash);
                const isSetEnabled = await controller.isSet(retrievedSetAddress);
                expect(isSetEnabled).to.eq(true);
            });

            it("should emit the correct CSTokenCreated event", async () => {
                const subjectPromise = subject();
                const retrievedSetAddress = await protocolUtils.getCreatedCSTokenAddress((await subjectPromise).hash);

                await expect(subjectPromise).to.emit(setTokenCreator, "CSTokenCreated").withArgs(
                    retrievedSetAddress,
                    subjectManager,
                    subjectName,
                    subjectSymbol
                );
            });

            describe("when no components are passed in", async () => {
                beforeEach(async () => {
                    subjectComponents = [];
                });

                it("should revert", async () => {
                    await expect(subject()).to.be.revertedWith("Must have at least 1 component");
                });
            });

            describe("when no components have a duplicate", async () => {
                beforeEach(async () => {
                    subjectComponents = [firstComponent.address, firstComponent.address];
                });

                it("should revert", async () => {
                    await expect(subject()).to.be.revertedWith("Components must not have a duplicate");
                });
            });

            describe("when the component and units arrays are not the same length", async () => {
                beforeEach(async () => {
                    subjectUnits = [ether(1)];
                });

                it("should revert", async () => {
                    await expect(subject()).to.be.revertedWith("Component and unit lengths must be the same");
                });
            });

            describe("when a module is not approved by the Controller", async () => {
                beforeEach(async () => {
                    const invalidModuleAddress = await getRandomAddress();

                    subjectModules = [firstModule, invalidModuleAddress];
                });

                it("should revert", async () => {
                    await expect(subject()).to.be.revertedWith("Must be enabled module");
                });
            });

            describe("when no modules are passed in", async () => {
                beforeEach(async () => {
                    subjectModules = [];
                });

                it("should revert", async () => {
                    await expect(subject()).to.be.revertedWith("Must have at least 1 module");
                });
            });

            describe("when the manager is a null address", async () => {
                beforeEach(async () => {
                    subjectManager = ADDRESS_ZERO;
                });

                it("should revert", async () => {
                    await expect(subject()).to.be.revertedWith("Manager must not be empty");
                });
            });

            describe("when a component is a null address", async () => {
                beforeEach(async () => {
                    subjectComponents = [firstComponent.address, ADDRESS_ZERO];
                });

                it("should revert", async () => {
                    await expect(subject()).to.be.revertedWith("Component must not be null address");
                });
            });

            describe("when a unit is 0", async () => {
                beforeEach(async () => {
                    subjectUnits = [ONE, ZERO];
                });

                it("should revert", async () => {
                    await expect(subject()).to.be.revertedWith("Units must be greater than 0");
                });
            });
        });
    });
});