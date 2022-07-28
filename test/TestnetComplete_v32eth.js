const {deployments} = require('hardhat');
const {ethers} = require('hardhat');
const chai = require('chai');
require('solidity-coverage');
const expect = chai.expect;
const { deploymentVariables, waitConfirmations } = require("../helpers/variables");
const { network } = require("hardhat")

describe('Complete32eth', () => {
  let owner, aliceWhale, operator, bob;
  let factoryContract, serviceContractIndex, tokenContract;
  let serviceContracts = [];

  beforeEach(async function () {
    if (network.config.type == 'hardhat') await deployments.fixture();
    [owner, aliceWhale, bob, operator] = await ethers.getSigners();
    // get factory deployment
    const factoryDeployment = await deployments.get('SenseistakeServicesContractFactory')
    const contrFactory = await ethers.getContractFactory(
      'SenseistakeServicesContractFactory'
    );
    factoryContract = await contrFactory.attach(factoryDeployment.address);
    // get service contract index
    // serviceContractIndex = await factoryContract.getLastIndexServiceContract()
    serviceContractIndex = deploymentVariables.servicesToDeploy;
    // get token deployment
    const tokenDeployment = await deployments.get('SenseistakeERC20Wrapper')
    const contrToken = await ethers.getContractFactory(
      'SenseistakeERC20Wrapper'
    );
    tokenContract = await contrToken.attach(tokenDeployment.address);
    // get all service contracts deployed
    for( let i = 1 ; i <= serviceContractIndex; i++) {
      const { address: salt } = await deployments.get('ServiceContractSalt'+i)
      const serviceDeployment = await deployments.get('SenseistakeServicesContract'+i)
      const contrService = await ethers.getContractFactory(
          'SenseistakeServicesContract'
      );
      serviceContracts.push({
        salt,
        sc: await contrService.attach(serviceDeployment.address)
      });
    }
  });

  it('0. should revert when less than 32eth are deposited', async function () {
    const { salt, sc } = serviceContracts[0];
    let amount = "5000000000000000000"
    const tx = factoryContract.connect(aliceWhale).fundMultipleContracts([salt], {
      value: amount
    });
    await expect(tx).to.be.revertedWith('Deposited amount should be greater than minimum deposit');
  })


  it('1. should be able to 32eth or multiples of 32eth and withdraw them', async function () {
    /*
      1. deposit 32 eth
      2. withdraw 32 eth
    */
    const { salt, sc } = serviceContracts[0];
    let balances = {
      sc: {},
      token: {}
    }
    let amount = "32000000000000000000"
    balances.sc.before_1 = (await sc.getDeposit(aliceWhale.address)).toString()
    balances.token.before_1 = (await tokenContract.balanceOf(aliceWhale.address)).toString()
    const tx = await factoryContract.connect(aliceWhale).fundMultipleContracts([salt], {
      value: amount
    });
    await tx.wait(waitConfirmations[network.config.type]);
    balances.sc.after_1 = (await sc.getDeposit(aliceWhale.address)).toString()
    balances.token.after_1 = (await tokenContract.balanceOf(aliceWhale.address)).toString()
    expect(balances.sc.after_1 - balances.sc.before_1).to.be.equal(parseInt(amount));
    expect(balances.token.after_1 - balances.token.before_1).to.be.equal(parseInt(amount));

    balances.sc.before_2 = (await sc.getDeposit(aliceWhale.address)).toString()
    balances.token.before_2 = (await tokenContract.balanceOf(aliceWhale.address)).toString()

    const withdrawAllowance = await factoryContract.connect(aliceWhale).increaseWithdrawalAllowance(amount);
    const withdraw = await factoryContract.connect(aliceWhale).withdrawAll();
    await withdraw.wait(waitConfirmations[network.config.type]);
    balances.sc.after_2 = (await sc.getDeposit(aliceWhale.address)).toString()
    balances.token.after_2 = (await tokenContract.balanceOf(aliceWhale.address)).toString()
    expect(balances.sc.after_2 - balances.sc.before_2).to.be.equal(parseInt(0));
    expect(balances.token.after_2 - balances.token.before_2).to.be.equal(parseInt(0));
  });
});