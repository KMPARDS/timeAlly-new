const assert = require('assert');
const ethers = require('ethers');

const ganache = require('ganache-cli');

const numberOfAccounts = 1000;
console.log(`\nGenerating ${numberOfAccounts} demo accounts...`);
const provider = new ethers.providers.Web3Provider(ganache.provider({ gasLimit: 8100000, total_accounts: numberOfAccounts }));

const eraSwapTokenJSON = require('./build/Eraswap_0.json');
const nrtManagerJSON = require('./build/NRTManager_0.json');
const timeAllyJSON = require('./build/TimeAlly_0.json');

let accounts
, eraSwapInstance = []
, nrtManagerInstance = []
, timeAllyInstance = [];

(async() => {
  accounts = await provider.listAccounts();
  console.log('numberOfAccounts created', accounts.length);
  console.log('Done\n');


  // deploying token contract
  const eraSwapContract = new ethers.ContractFactory(
    eraSwapTokenJSON.abi,
    eraSwapTokenJSON.evm.bytecode.object,
    provider.getSigner(accounts[0])
  );
  eraSwapInstance[0] =  await eraSwapContract.deploy();


  // deploying NRT
  const nrtManagerContract = new ethers.ContractFactory(
    nrtManagerJSON.abi,
    nrtManagerJSON.evm.bytecode.object,
    provider.getSigner(accounts[0])
  );
  nrtManagerInstance[0] = await nrtManagerContract.deploy(eraSwapInstance[0].address);

  await eraSwapInstance[0].functions.AddNRTManager(nrtManagerInstance[0].address);


  // deploying TimeAlly
  const timeAllyContract = new ethers.ContractFactory(
    timeAllyJSON.abi,
    timeAllyJSON.evm.bytecode.object,
    provider.getSigner(accounts[0])
  );
  timeAllyInstance[0] = await timeAllyContract.deploy(
    eraSwapInstance[0].address,
    nrtManagerInstance[0].address,
    {gasLimit: 8000000}
  );

  // adding timeAlly to NRT
  await nrtManagerInstance[0].UpdateAddresses([
    "0x0000000000000000000000000000000000000000",
    "0x0000000000000000000000000000000000000000",
    "0x0000000000000000000000000000000000000000",
    "0x0000000000000000000000000000000000000000",
    "0x0000000000000000000000000000000000000000",
    "0x0000000000000000000000000000000000000000",
    "0x0000000000000000000000000000000000000000",
    "0x0000000000000000000000000000000000000000",
    timeAllyInstance[0].address
  ]);

  // creating plans
  await Promise.all([
    timeAllyInstance[0].createStakingPlan(12, 13, false),
    timeAllyInstance[0].createStakingPlan(24, 15, false)
  ]);


  //await eraSwapInstance[0].functions.transfer(accounts[accountId], ethers.utils.parseEther(amount));

  await eraSwapInstance[0].functions.approve(timeAllyInstance[0].address, ethers.utils.parseEther('30').mul(2000));

  await timeAllyInstance[0].functions.topupRewardBucket(ethers.utils.parseEther('30')
  .mul(2000));


  //let n = 1;
  let i = 600;

  while(i < numberOfAccounts) {
    const sendAccounts = [];
    const amounts = [];

    for(j = 1; j < i; j++) {
      sendAccounts.push(accounts[i]);
      amounts.push(ethers.utils.parseEther('30'));
      // n = i;
    }
    console.log(`for ${i}, gas needed is`,(
      await timeAllyInstance[0].estimate.giveLaunchReward(sendAccounts, amounts)
    ).toString());

    i = i + 1;
    // sendAccounts.push(accounts[i++]);
    //console.log(accounts[n++]);

  }

})();
