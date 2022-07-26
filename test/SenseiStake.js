const {deployments} = require('hardhat');
const {ethers} = require('hardhat');
const {utils} = {ethers};
const chai = require('chai');
require('solidity-coverage');
const expect = chai.expect;
const { deploymentVariables, waitConfirmations } = require("../helpers/variables");
const { network } = require("hardhat")
const should = chai.should();

describe('SenseiStake', () => {
  let owner, aliceWhale, otherPerson, bob;
  let serviceContractIndex, tokenContract, contrService;
  let serviceContracts = [];

  beforeEach(async function () {
    if (network.config.type == 'hardhat') await deployments.fixture();
    [owner, aliceWhale, bob, otherPerson] = await ethers.getSigners();
    
    // get service contract index
    serviceContractIndex = deploymentVariables.servicesToDeploy;
    
    // get token deployment
    const tokenDeployment = await deployments.get('SenseiStake')
    const contrToken = await ethers.getContractFactory(
      'SenseiStake'
    );
    tokenContract = await contrToken.attach(tokenDeployment.address);

    // get deposit contract
    const depositContractDeployment = await deployments.get('DepositContract')
    const depContract = await ethers.getContractFactory(
        'DepositContract'
    );
    depositContract = await depContract.attach(depositContractDeployment.address);
    
    contrService = await ethers.getContractFactory(
        'SenseistakeServicesContract'
    );
    //utils.hexZeroPad(utils.hexlify(index), 32)
  });

  describe('1. addValidator should fail if incorrect data provided', async function () {
    const correctLenBytes = {
        tokenId:1,
        validatorPubKey: 48,
        depositSignature: 96,
        depositDataRoot: 32,
        depositMessageRoot: 32,
    }
    it('1.1 Should fail if wrong length: validatorPubKey', async function () {
        const addValidator = tokenContract.addValidator(
            correctLenBytes['tokenId'],
            ethers.utils.hexZeroPad(ethers.utils.hexlify(5), correctLenBytes['validatorPubKey']-2),
            ethers.utils.hexZeroPad(ethers.utils.hexlify(5), correctLenBytes['depositSignature']),
            ethers.utils.hexZeroPad(ethers.utils.hexlify(5), correctLenBytes['depositDataRoot']),
        )
        await expect(addValidator).to.be.revertedWith("InvalidPublicKey");
    })
    it('1.2 Should fail if wrong length: depositSignature', async function () {
        const addValidator = tokenContract.addValidator(
            correctLenBytes['tokenId'],
            ethers.utils.hexZeroPad(ethers.utils.hexlify(5), correctLenBytes['validatorPubKey']),
            ethers.utils.hexZeroPad(ethers.utils.hexlify(5), correctLenBytes['depositSignature']-2),
            ethers.utils.hexZeroPad(ethers.utils.hexlify(5), correctLenBytes['depositDataRoot']),
        )
        await expect(addValidator).to.be.revertedWith("InvalidDepositSignature");
    })
    it('1.3 Should fail if wrong length: depositDataRoot', async function () {
        const addValidator = tokenContract.addValidator(
            correctLenBytes['tokenId'],
            ethers.utils.hexZeroPad(ethers.utils.hexlify(5), correctLenBytes['validatorPubKey']),
            ethers.utils.hexZeroPad(ethers.utils.hexlify(5), correctLenBytes['depositSignature']),
            ethers.utils.hexZeroPad(ethers.utils.hexlify(5), correctLenBytes['depositDataRoot']-2),
        )
        await expect(addValidator).to.be.reverted;
    })
    it('1.5 Should fail if tokenId provided already used (and minted)', async function () {
        await tokenContract.connect(aliceWhale).createContract({
            value: ethers.utils.parseEther("32")
        });
        const addValidator = tokenContract.addValidator(
            correctLenBytes['tokenId'],
            ethers.utils.hexZeroPad(ethers.utils.hexlify(1), correctLenBytes['validatorPubKey']),
            ethers.utils.hexZeroPad(ethers.utils.hexlify(1), correctLenBytes['depositSignature']),
            ethers.utils.hexZeroPad(ethers.utils.hexlify(1), correctLenBytes['depositDataRoot']),
        )
        await expect(addValidator).to.be.revertedWith("TokenIdAlreadyMinted");
    })
    it('1.6 Should fail if validator was already added', async function () {
        const addValidator = await tokenContract.addValidator(
            correctLenBytes['tokenId'],
            ethers.utils.hexZeroPad(ethers.utils.hexlify(1), correctLenBytes['validatorPubKey']),
            ethers.utils.hexZeroPad(ethers.utils.hexlify(1), correctLenBytes['depositSignature']),
            ethers.utils.hexZeroPad(ethers.utils.hexlify(1), correctLenBytes['depositDataRoot']),
        )
        const addValidator2 = tokenContract.addValidator(
            correctLenBytes['tokenId'],
            ethers.utils.hexZeroPad(ethers.utils.hexlify(1), correctLenBytes['validatorPubKey']),
            ethers.utils.hexZeroPad(ethers.utils.hexlify(1), correctLenBytes['depositSignature']),
            ethers.utils.hexZeroPad(ethers.utils.hexlify(1), correctLenBytes['depositDataRoot']),
        )
        await expect(addValidator2).to.be.revertedWith("ValidatorAlreadyAdded");
    });
  });

  describe('2. createContract should fail if incorrect data provided', async function () {
    it('2.1 Should fail if more than 32 ETH being sent', async function () {
        const createContract = tokenContract.connect(aliceWhale).createContract({
            value: ethers.utils.parseEther("33")
        });
        await expect(createContract).to.be.revertedWith("ValueSentDifferentThanFullDeposit");

    });
    it('2.2 Should fail if less than 32 ETH being sent', async function () {
        const createContract = tokenContract.connect(aliceWhale).createContract({
            value: ethers.utils.parseEther("31")
        });
        await expect(createContract).to.be.revertedWith("ValueSentDifferentThanFullDeposit");
    });
    it('2.3 Should fail if no more validators available', async function () {
        // we have added previously 2, so the third will fail
        await tokenContract.connect(aliceWhale).createContract({
            value: ethers.utils.parseEther("32")
        });
        await tokenContract.connect(aliceWhale).createContract({
            value: ethers.utils.parseEther("32")
        });
        const createContract = tokenContract.connect(aliceWhale).createContract({
            value: ethers.utils.parseEther("32")
        });
        await expect(createContract).to.be.revertedWith("NoMoreValidatorsLoaded");
    });
  });

  describe('3. endOperatorServices should fail if incorrect data provided', async function () {
    it('3.1 Should fail caller is not token owner or not contract deployer', async function () {
        await tokenContract.connect(aliceWhale).createContract({
            value: ethers.utils.parseEther("32")
        });
        const endOperatorServices = tokenContract.connect(otherPerson).endOperatorServices(1);
        await expect(endOperatorServices).to.be.revertedWith("NotOwner");

    });
    it('3.2 Should not be able to retrieve full validator deposit if called withdraw', async function () {
        await tokenContract.connect(aliceWhale).createContract({
            value: ethers.utils.parseEther("32")
        });
        const sscc_addr = await tokenContract.getServiceContractAddress(1);
        
        // console.log('after mint', await tokenContract.balanceOf(aliceWhale.address));
        await aliceWhale.sendTransaction({to: sscc_addr, value: ethers.utils.parseEther('17')});
        await ethers.provider.send("evm_mine", [parseInt(new Date(2025, 0, 2).getTime() / 1000)]);
        
        // end operator services will result on zero commission
        await tokenContract.endOperatorServices(1);
        await tokenContract.connect(aliceWhale).withdraw(1);
        const balance = parseInt((await ethers.provider.getBalance(sscc_addr)).toString());
        await expect(balance).to.be.equals(0);

        // console.log('after exploit', await tokenContract.balanceOf(aliceWhale.address));

        // withdraw made but will result in token burn and thus cannot recover full validator deposit
        await expect(await tokenContract.balanceOf(aliceWhale.address)).to.be.equals(0);
    });
  });

  describe('4. withdraw should fail if incorrect data provided', async function () {
    it('2.1 Should fail caller is not token owner', async function () {
        await tokenContract.connect(aliceWhale).createContract({
            value: ethers.utils.parseEther("32")
        });
        const createContract = tokenContract.connect(otherPerson).withdraw(1);
        await expect(createContract).to.be.revertedWith("NotOwner");

    });
  });

  describe('5. transferOwnership should fail if incorrect data provided', async function () {
    it('5.1 Should fail caller is not contract deployer (owner)', async function () {
        const transferOwnership = tokenContract.connect(aliceWhale).transferOwnership(otherPerson.address);
        await expect(transferOwnership).to.be.revertedWith("Ownable: caller is not the owner");

    });
  });

  describe('6. renounceOwnership should fail if incorrect data provided', async function () {
    it('6.1 Should fail caller is not contract deployer (owner)', async function () {
        const renounceOwnership = tokenContract.connect(aliceWhale).renounceOwnership();
        await expect(renounceOwnership).to.be.revertedWith("Ownable: caller is not the owner");

    });
  });

  describe('7. transfer nft ownership', async function () {
    const token_id = 1;
    it('7.1 Should be successfull', async function () {
        await tokenContract.connect(aliceWhale).createContract({
            value: ethers.utils.parseEther("32")
        });
        const owner_before = await tokenContract.ownerOf(token_id);
        const transfer = await tokenContract.connect(aliceWhale).transferFrom(
            aliceWhale.address,
            otherPerson.address,
            token_id
        );
        const receipt = await transfer.wait(waitConfirmations[network.config.type]);
        const owner_after = await tokenContract.ownerOf(token_id);
        await expect(owner_before).to.be.equals(aliceWhale.address);
        await expect(owner_after).to.be.equals(otherPerson.address);
        await expect(owner_after).not.to.be.equals(owner_before);
    });
    it('7.2 Should fail if not owner', async function () {
        await tokenContract.connect(aliceWhale).createContract({
            value: ethers.utils.parseEther("32")
        });
        const transfer = tokenContract.connect(otherPerson).transferFrom(
            aliceWhale.address,
            otherPerson.address,
            token_id
        );
        await expect(transfer).to.be.revertedWith("ERC721: caller is not token owner nor approved");
    });
  });

  describe('8. test validatorAvailable', async function () {
    it('8.1 Should be available vaidator', async function () {
        await tokenContract.connect(aliceWhale).createContract({
            value: ethers.utils.parseEther("32")
        });
        expect(await tokenContract.connect(otherPerson).validatorAvailable()).to.equal(true)
    });
  });
});