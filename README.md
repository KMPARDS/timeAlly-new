# TimeAlly Smart Contract

TimeAlly is a meticulously crafted smart contract to reduce the volatility of Era Swap Token. It rewards users who choose to lock their tokens in the smart contract according to their vesting periods. TimeAlly is a very crucial part of the ecosystem as it controls some of the demand-supply dynamics of the token. TimeAlly acts as an elementary reward distribution method for users of multiple platforms of Era Swap Ecosystem.

## Steps to Test
Open `Terminal` (in macOS or Linux) or `Command prompt` (in Windows) of your computer
- `git clone https://github.com/zemse/timeAlly-new.git`
- `cd timeAlly-new`
- `npm i`
- `node compile.js`
- `npm test`

## Utility of TimeAlly
### Staking
- User comes to the contract and stakes ES. His/her ES amount is locked according to the plan he/she chooses.
- Every month, NRT sends some ES to the TimeAlly contract. This contract allocates portions of this ES to users proportional to the amount of active staking.
- User can withdraw upto 50% benefit share stored in TimeAlly anytime after NRT release and rest of the ES is stored in accrued. User can anytime make a new staking of amount accrued. Before withdrawing, user can read how much is his/her share for current and past months.

### Loan
- User can take loan upto 50% of it's staking. While loan is on, user will not receive monthly benefits.
- User can repay the loan in time as per loan plan and start receiving monthly benefits again.
