const { network } = require("hardhat");
require('dotenv').config({ path: require('find-config')('.env') })

const waitConfirmations = {
    ganache: 0,
    hardhat: 0,
    testnet: 2,
    mainnet: 2
}

const deploymentVariables = {
    servicesToDeploy: ['testnet', 'mainnet'].includes(network.config.type) ? 10 : 2,
    depositContractAddress: {
        1: '0x00000000219ab540356cBB839Cbe05303d7705Fa',
        5: '0xff50ed3d0ec03aC01D4C79aAd74928BFF48a7b2b'
    },
    keystorePassword: process.env.VALIDATOR_PASSPHRASE,
    keystorePasswordSSVTest: process.env.VALIDATOR_PASSPHRASE_SSV_TEST,
    waitConfirmations: waitConfirmations[network.config.type],
}

const mappingChainId = {
    mainnet: 1,
    goerli: 5
}

// const forkVersion = {
//     mainnet: '00000000',
//     goerli: '00001020'
// }

module.exports = { deploymentVariables, mappingChainId, waitConfirmations }