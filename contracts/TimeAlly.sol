pragma solidity ^0.5.10;

import './SafeMath.sol';
import './Eraswap.sol';
import './NRTManager.sol';

/*

Potential bugs: this contract is designed assuming NRT Release will happen every month.
There might be issues when the NRT scheduled

*/

contract TimeAlly {

    using SafeMath for uint256;

    struct Staking {
        uint256 exaEsAmount;
        uint256 timestamp;
        uint256 stakingPlanId;
        uint256 status; // 1 => active; 2 => loaned; 3 => withdrawed; 4 => cancelled; 5 => nominiee
        uint256 accruedExaEsAmount;
        uint256 loanId;
        uint256 refundMonthClaimedLast;
        uint256 refundMonthsRemaining;
        uint256 totalNominationShares;
        mapping (uint256 => bool) isMonthClaimed;
        mapping (address => uint256) nomination;
    }

    struct StakingPlan {
        uint256 months;
        uint256 fractionFrom15;
    }

    struct Loan {
        uint256 exaEsAmount;
        uint256 timestamp;
        uint256 loanPlanId;
        uint256 status;
        uint256[] stakingIds;
    }

    struct LoanPlan {
        uint256 loanMonths;
        uint256 loanRate;
    }


    address public owner;
    Eraswap public token;
    NRTManager public nrtManager;

    uint256 public deployedTimestamp;
    uint256 public earthSecondsInMonth = 2629744;

    //uint256 public currentMonth;
    uint256[] public timeAllyMonthlyNRT; //current month is the length of this array

    // if StakePlan has only one member then make it uint256[]
    StakingPlan[] public stakingPlans;
    LoanPlan[] public loanPlans;

    // user activity details:
    mapping(address => Staking[]) public stakings;
    mapping(address => Loan[]) public loans;
    //mapping(address => mapping (uint256 => bool)) monthClaim;

    mapping (uint256 => uint256) public totalActiveStakings;

    uint256 public launchRewardBucket;
    mapping(address => uint256) public launchReward;

    // need stakingid in this
    event NewStaking (
        address indexed _userAddress,
        uint256 indexed _stakePlanId,
        uint256 _exaEsAmount,
        uint256 _stakingId
    );

    event Nominee (
        address indexed _userAddress,
        uint256 indexed _stakingId,
        address indexed _nomineeAddress,
        uint256 _shares
    );

    event BenefitWithdrawl (
        address indexed _userAddress,
        uint256 _atMonth,
        uint256 _accruedPercentage,
        bool _stakeAccruedNow,
        uint256 _newStakingId // meaningless if bool is false
    );

    event NewLoan (
        address indexed _userAddress,
        uint256 indexed _loanPlanId,
        uint256 _exaEsAmount,
        uint256 _loanInterest,
        uint256 _loanId
    );

    event RepayLoan (
        address indexed _userAddress,
        uint256 _loanId
    );

    modifier onlyNRTManager() {
        require(msg.sender == address(nrtManager), 'only NRT manager can call');
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, 'only deployer can call');
        _;
    }

    constructor(address _tokenAddress, address _nrtAddress) public {
        owner = msg.sender;
        token = Eraswap(_tokenAddress);
        nrtManager = NRTManager(_nrtAddress);
        deployedTimestamp = token.mou();
        timeAllyMonthlyNRT.push(0);
    }

    function increaseMonth(uint256 _timeAllyNRT) public onlyNRTManager {
        timeAllyMonthlyNRT.push(_timeAllyNRT);
    }

    function getCurrentMonth() public view returns (uint256) {
        return timeAllyMonthlyNRT.length - 1;
    }

    function createStakingPlan(uint256 _months, uint256 _fractionFrom15) public onlyOwner {
        stakingPlans.push(StakingPlan({
            months: _months,
            fractionFrom15: _fractionFrom15
        }));
    }

    function createLoanPlan(uint256 _loanMonths, uint256 _loanRate) public onlyOwner {
        loanPlans.push(LoanPlan({
            loanMonths: _loanMonths,
            loanRate: _loanRate
        }));
    }

    // takes ES from user and locks it for a time
    function newStaking(uint256 _exaEsAmount, uint256 _stakingPlanId, address[] memory _nomineeArray, uint256[] memory _perThousandShareArray) public {
        require(token.transferFrom(msg.sender, address(this), _exaEsAmount), 'could not transfer tokens');
        uint256 _stakeEndMonth = getCurrentMonth() + 1 + stakingPlans[_stakingPlanId].months;

        // update the array so that staking would be automatically inactive after the stakingPlanMonthhs
        for(
          uint256 _month = getCurrentMonth() + 1;
          _month < _stakeEndMonth;
          month++
        ) {
            totalActiveStakings[_month] = totalActiveStakings[_month].add(_exaEsAmount);
        }

        stakings[msg.sender].push(Staking({
            exaEsAmount: _exaEsAmount,
            timestamp: token.mou(),
            stakingPlanId: _stakingPlanId,
            status: 1,
            accruedExaEsAmount: 0,
            loanId: 0,
            refundMonthClaimedLast: 0,
            refundMonthsRemaining: 0,
            totalNominationShares: 0
        }));

        uint256 _stakingId = stakings[msg.sender].length - 1;
        emit NewStaking(msg.sender, _stakingPlanId, _exaEsAmount, _stakingId);

        for(uint256 i = 0; i < _nomineeArray.length; i++) {
            stakings[msg.sender][_stakingId].totalNominationShares = stakings[msg.sender][_stakingId].totalNominationShares.add(_perThousandShareArray[i])
            stakings[msg.sender][_stakingId].nomination[_nomineeArray[i]] = _perThousandShareArray[i];
            emit Nominee(msg.sender, _stakingPlanId, _nomineeArray[i], _perThousandShareArray[i]);
        }
    }

    function getNumberOfStakingsByUser(address _userAddress) public view returns (uint256) {
        return stakings[_userAddress].length;
    }

    // view stakes of a user
    function viewStaking(
        address _userAddress,
        uint256 _stakingId
    ) public view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        return (
            stakings[_userAddress][_stakingId].exaEsAmount,
            stakings[_userAddress][_stakingId].timestamp,
            stakings[_userAddress][_stakingId].stakingPlanId,
            stakings[_userAddress][_stakingId].status,
            stakings[_userAddress][_stakingId].accruedExaEsAmount,
            stakings[_userAddress][_stakingId].loanId
        );
    }

    function topupRewardBucket(uint256 _exaEsAmount) public onlyOwner {
        require(token.transferFrom(msg.sender, address(this), _exaEsAmount));
        launchRewardBucket = launchRewardBucket.add(_exaEsAmount);
    }

    function giveLaunchReward(address[] memory _addresses, uint256 _exaEsAmount) public onlyOwner {
        for(uint256 i = 0; i < _addresses.length; i++) {
            launchRewardBucket = launchRewardBucket.sub(_exaEsAmount);
            launchReward[_addresses[i]] = launchReward[_addresses[i]].add(_exaEsAmount);
        }
    }

    function giveLaunchRewardSeperate(address[] memory _addresses, uint256[] memory _exaEsAmounts) public onlyOwner {
        for(uint256 i = 0; i < _addresses.length; i++) {
            launchRewardBucket = launchRewardBucket.sub(_exaEsAmounts[i]);
            launchReward[_addresses[i]] = launchReward[_addresses[i]].add(_exaEsAmounts[i]);
        }
    }

    function claimLaunchReward(uint256 _stakingPlanId) public {
        require(launchReward[msg.sender] > 0);
        uint256 reward = launchReward[msg.sender];
        launchReward[msg.sender] = 0;

        // create new staking
        uint256 stakeEndMonth = getCurrentMonth() + 1 + stakingPlans[_stakingPlanId].months;

        // update the array so that staking would be automatically inactive after the stakingPlanMonthhs
        for(
          uint256 month = getCurrentMonth() + 1;
          month < stakeEndMonth;
          month++
        ) {
            totalActiveStakings[month] = totalActiveStakings[month] + reward;
        }

        Staking[] storage userStakingsArray = stakings[msg.sender];
        userStakingsArray.push(Staking({
            exaEsAmount: reward,
            timestamp: token.mou(),
            stakingPlanId: _stakingPlanId,
            status: 1,
            accruedExaEsAmount: 0,
            loanId: 0,
            refundMonthClaimedLast: 0,
            refundMonthsRemaining: 0
        }));

        emit NewStaking(msg.sender, _stakingPlanId, reward, userStakingsArray.length - 1);
    }

    // returns true is staking is in correct time frame and also no loan on it
    function isStakingActive(address _userAddress, uint256 _stakingId, uint256 _currentMonth, uint256 _atMonth) public view returns (bool) {
      uint256 stakingMonth = stakings[_userAddress][_stakingId].timestamp.sub(deployedTimestamp).div(earthSecondsInMonth);

      return (
        stakingMonth + 1 <= _atMonth && stakingMonth + stakingPlans[ stakings[_userAddress][_stakingId].stakingPlanId ].months >= _atMonth
        && stakings[_userAddress][_stakingId].status == 1
        && (
          _currentMonth != _atMonth
          || token.mou() >= stakings[_userAddress][_stakingId].timestamp
                      .add( (_currentMonth - stakingMonth).mul(earthSecondsInMonth) )
          )
        );
    }

    function userActiveStakingByMonth(address _userAddress, uint256 _atMonth) public view returns (uint256) {
        // calculate user's active stakings amount for this month
        // divide by total active stakings to get the fraction.
        // multiply by the total timeally NRT to get the share and send it to user

        uint256 _currentMonth = getCurrentMonth();
        //require(_currentMonth >= _atMonth, 'cannot see future stakings');

        uint256 userActiveStakingsExaEsAmount;

        for(uint256 i = 0; i < stakings[_userAddress].length; i++) {

            // user staking should be active for it to be considered
            if(isStakingActive(_userAddress, i, _currentMonth, _atMonth)) {
                userActiveStakingsExaEsAmount = userActiveStakingsExaEsAmount
                    .add(stakings[_userAddress][i].exaEsAmount);
                    // .mul(stakingPlans[ stakings[_userAddress][i].stakingPlanId ].fractionFrom15)
                    // .div(15));
            }
        }

        return userActiveStakingsExaEsAmount;
    }

    function userEffectiveStakingByMonth(address _userAddress, uint256 _atMonth) public view returns (uint256) {
        // calculate user's active stakings amount for this month
        // divide by total active stakings to get the fraction.
        // multiply by the total timeally NRT to get the share and send it to user

        uint256 _currentMonth = getCurrentMonth();
        //require(_currentMonth >= _atMonth, 'cannot see future stakings');

        uint256 userActiveStakingsExaEsAmount;

        for(uint256 i = 0; i < stakings[_userAddress].length; i++) {

            // user staking should be active for it to be considered
            if(isStakingActive(_userAddress, i, _currentMonth, _atMonth)) {
                userActiveStakingsExaEsAmount = userActiveStakingsExaEsAmount
                    .add(stakings[_userAddress][i].exaEsAmount
                      .mul(stakingPlans[ stakings[_userAddress][i].stakingPlanId ].fractionFrom15)
                      .div(15));
            }
        }

        return userActiveStakingsExaEsAmount;
    }


    function seeShareForUserByMonth(address _userAddress, uint256 _atMonth) public view returns (uint256) {
        // calculate user's active stakings amount for this month
        // divide by total active stakings to get the fraction.
        // multiply by the total timeally NRT to get the share and send it to user

        uint256 _currentMonth = getCurrentMonth();
        require(_atMonth <= _currentMonth, 'cannot see future stakings');

        if(totalActiveStakings[_atMonth] == 0) {
            return 0;
        }

        uint256 userActiveStakingsExaEsAmount;

        for(uint256 i = 0; i < stakings[_userAddress].length; i++) {
            StakingPlan memory plan = stakingPlans[ stakings[_userAddress][i].stakingPlanId ];

            // user staking should be active for it to be considered
            if(isStakingActive(_userAddress, i, _currentMonth, _atMonth)
              && !stakings[_userAddress][i].isMonthClaimed[_atMonth]) {
                userActiveStakingsExaEsAmount = userActiveStakingsExaEsAmount.add(stakings[_userAddress][i].exaEsAmount.mul(plan.fractionFrom15).div(15));
            }
        }

        return userActiveStakingsExaEsAmount.mul(timeAllyMonthlyNRT[_atMonth]).div(totalActiveStakings[_atMonth]);
    }

    function withdrawShareForUserByMonth(uint256 _atMonth, uint256 _accruedPercentage, bool _stakeAccruedNow, uint256 _accruedsStakingPlan) public {
        uint256 _currentMonth = getCurrentMonth();

        require(_currentMonth >= _atMonth, 'cannot withdraw future stakings');

        if(totalActiveStakings[_atMonth] == 0) {
            require(false, 'total active stakings should be non zero');
        }

        require(_accruedPercentage >= 50, 'accruedPercentage should be at least 50');

        uint256 _userActiveStakingsExaEsAmount;
        uint256 _shareTotalCurrentAccrued;

        for(uint256 i = 0; i < stakings[msg.sender].length; i++) {
            StakingPlan memory _plan = stakingPlans[ stakings[msg.sender][i].stakingPlanId ];

            // user staking should be active for it to be considered
            if(isStakingActive(msg.sender, i, _currentMonth, _atMonth)
              && !stakings[msg.sender][i].isMonthClaimed[_atMonth]) {
                stakings[msg.sender][i].isMonthClaimed[_atMonth] = true;

                // for every staking, incrementing its accrued amount
                uint256 _effectiveAmount = stakings[msg.sender][i].exaEsAmount.mul(_plan.fractionFrom15).div(15);
                uint256 _accruedShare = _effectiveAmount
                                          .mul(timeAllyMonthlyNRT[_currentMonth])
                                          .div(totalActiveStakings[_currentMonth])
                                          .mul(_accruedPercentage).div(100);
                if(_stakeAccruedNow) {
                    // add this number to temp variable and make staking of it in the end
                    _shareTotalCurrentAccrued = _shareTotalCurrentAccrued.add(_accruedShare);
                } else {
                    // mark the accrued in the staking
                    stakings[msg.sender][i].accruedExaEsAmount = stakings[msg.sender][i].accruedExaEsAmount.add(_accruedShare);
                }
                _userActiveStakingsExaEsAmount = _userActiveStakingsExaEsAmount.add(_effectiveAmount);
            }
        }

        uint256 _liquidShare = _userActiveStakingsExaEsAmount
                                .mul(timeAllyMonthlyNRT[_currentMonth])
                                .div(totalActiveStakings[_currentMonth])
                                .mul(100 - _accruedPercentage).div(100);

        if(_liquidShare > 0) {
            token.transfer(msg.sender, _liquidShare);
        }

        if(_stakeAccruedNow) {
            newStaking(_shareTotalCurrentAccrued, _accruedsStakingPlan);
        }
    }

    function restakeAccrued(uint256 _stakingId, uint256 _stakingPlanId) public {
        require(stakings[msg.sender][_stakingId].accruedExaEsAmount > 0);

        uint256 _accruedExaEsAmount = stakings[msg.sender][_stakingId].accruedExaEsAmount;
        stakings[msg.sender][_stakingId].accruedExaEsAmount = 0;
        newStaking(
          _accruedExaEsAmount,
          _stakingPlanId
        );
    }

    // give in input which which stakings to withdeaw
    function withdrawExpiredStakings(uint256[] memory _stakings) public {
        for(uint256 i = 0; i < _stakings.length; i++) {
            stakings[msg.sender][_stakings[i]].status = 3;

            if(stakings[msg.sender][_stakings[i]].accruedExaEsAmount > 0) {
              uint256 accruedExaEsAmount = stakings[msg.sender][_stakings[i]].accruedExaEsAmount;
              stakings[msg.sender][_stakings[i]].accruedExaEsAmount = 0;
              newStaking(
                accruedExaEsAmount,
                stakings[msg.sender][_stakings[i]].stakingPlanId
              );
            }

            token.transfer(msg.sender, stakings[msg.sender][_stakings[i]].exaEsAmount);
        }
    }

    function cancelStaking(uint256 _stakingId) public {
        require(stakings[msg.sender][_stakingId].status == 1, 'to cansal, staking must be active');

        stakings[msg.sender][_stakingId].status = 4;

        uint256 _currentMonth = getCurrentMonth();

        uint256 stakingStartMonth = stakings[msg.sender][_stakingId].timestamp.sub(deployedTimestamp).div(earthSecondsInMonth);

        uint256 stakeEndMonth = stakingStartMonth + stakingPlans[stakings[msg.sender][_stakingId].stakingPlanId].months;

        for(uint256 j = _currentMonth + 1; j <= stakeEndMonth; j++) {
            totalActiveStakings[j] = totalActiveStakings[j].sub(stakings[msg.sender][_stakingId].exaEsAmount);
        }

        // logic for 24 month withdraw
        stakings[msg.sender][_stakingId].refundMonthClaimedLast = getCurrentMonth();
        stakings[msg.sender][_stakingId].refundMonthsRemaining = 24;
    }

    function withdrawCancelStaking(uint256 _stakingId) public {
        // calculate how much months can be withdrawn and mark it and transfer it to user.

        require(stakings[msg.sender][_stakingId].status == 4, 'staking must be cancelled');
        require(stakings[msg.sender][_stakingId].refundMonthsRemaining > 0, 'all refunds are claimed');

        uint256 _currentMonth = getCurrentMonth();

        // the last month to current month would tell months not claimed
        // min ( diff, remaining ) must be taken

        uint256 _withdrawMonths = _currentMonth.sub(stakings[msg.sender][_stakingId].refundMonthClaimedLast);

        if(_withdrawMonths > stakings[msg.sender][_stakingId].refundMonthsRemaining) {
            _withdrawMonths = stakings[msg.sender][_stakingId].refundMonthsRemaining;
        }

        uint256 _amountToTransfer = stakings[msg.sender][_stakingId].exaEsAmount
                                      .mul(_withdrawMonths).div(24);

        stakings[msg.sender][_stakingId].refundMonthClaimedLast = getCurrentMonth();
        stakings[msg.sender][_stakingId].refundMonthsRemaining = stakings[msg.sender][_stakingId].refundMonthsRemaining.sub(_withdrawMonths);

        token.transfer(msg.sender, _amountToTransfer);

    }

    function timeAllyMonthlyNRTArray() public view returns (uint256[] memory) {
        return timeAllyMonthlyNRT;
    }

    function seeMaxLoaningAmountOnUserStakings(address _userAddress, uint256[] memory _stakingIds) public view returns (uint256) {
        //uint256 _currentMonth = getCurrentMonth();
        //require(_currentMonth >= _atMonth, 'cannot see future stakings');

        uint256 userStakingsExaEsAmount;

        for(uint256 i = 0; i < _stakingIds.length; i++) {
            if(stakings[_userAddress][_stakingIds[i]].status == 1
            //if(isStakingActive(_userAddress, _stakingIds[i], _currentMonth, _currentMonth)
              // && !stakings[_userAddress][_stakingIds[i]].isMonthClaimed[_currentMonth]
            ) {
                userStakingsExaEsAmount = userStakingsExaEsAmount
                    .add(stakings[_userAddress][_stakingIds[i]].exaEsAmount);
                    // .mul(stakingPlans[ stakings[_userAddress][_stakingIds[i]].stakingPlanId ].fractionFrom15)
                    // .div(15));
            }
        }

        return userStakingsExaEsAmount.div(2);
            //.mul( uint256(100).sub(loanPlans[_loanPlanId].loanRate) ).div(100);
    }

    function takeLoanOnSelfStaking(uint256 _loanPlanId, uint256 _exaEsAmount, uint256[] memory _stakingIds) public {
        // when loan is to be taken, first calculate active stakings from given stakings array. this way we can get how much loan user can take and simultaneously mark stakings as claimed for next months number loan period
        uint256 _currentMonth = getCurrentMonth();
        uint256 _userStakingsExaEsAmount;

        for(uint256 i = 0; i < _stakingIds.length; i++) {

            //if( isStakingActive(msg.sender, _stakingIds[i], _currentMonth, _currentMonth) ) {
            if( stakings[msg.sender][_stakingIds[i]].status == 1 ) {
                // store sum in a number
                _userStakingsExaEsAmount = _userStakingsExaEsAmount
                    .add(
                        stakings[msg.sender][ _stakingIds[i] ].exaEsAmount
                        // .mul( stakingPlans[ stakings[msg.sender][_stakingIds[i]].stakingPlanId ].fractionFrom15 )
                        // .div(15)
                );

                // subtract total active stakings
                uint256 stakingStartMonth = stakings[msg.sender][_stakingIds[i]].timestamp.sub(deployedTimestamp).div(earthSecondsInMonth);

                uint256 stakeEndMonth = stakingStartMonth + stakingPlans[stakings[msg.sender][_stakingIds[i]].stakingPlanId].months;

                for(uint256 j = _currentMonth + 1; j <= stakeEndMonth; j++) {
                    totalActiveStakings[j] = totalActiveStakings[j].sub(_userStakingsExaEsAmount);
                }

                //make stakings inactive
                for(uint256 j = 1; j <= loanPlans[_loanPlanId].loanMonths; j++) {
                    stakings[msg.sender][ _stakingIds[i] ].isMonthClaimed[ _currentMonth + j ] = true;
                    stakings[msg.sender][ _stakingIds[i] ].status = 2; // means in loan
                }
            }
        }

        uint256 _maxLoaningAmount = _userStakingsExaEsAmount.div(2);

        if(_exaEsAmount > _maxLoaningAmount) {
            require(false, 'cannot loan more than maxLoaningAmount');
        }


        uint256 _loanInterest = _exaEsAmount.mul(loanPlans[_loanPlanId].loanRate).div(100);
        uint256 _loanAmountToTransfer = _exaEsAmount.sub(_loanInterest);

        require( token.transfer(address(nrtManager), _loanInterest) );
        require( nrtManager.UpdateLuckpool(_loanInterest) );

        // change this logic and make all stakings inactive, subtract all of them from the calender
        // // subtract total active stakings
        // for(uint256 i = 1; i <= loanPlans[_loanPlanId].loanMonths; i++) {
        //     if(totalActiveStakings[_currentMonth + i] > _userStakingsExaEsAmount) {
        //         totalActiveStakings[_currentMonth + i] = totalActiveStakings[_currentMonth + i].sub(_userStakingsExaEsAmount);
        //     } else {
        //         totalActiveStakings[_currentMonth + i] = 0;
        //     }
        // }

        loans[msg.sender].push(Loan({
            exaEsAmount: _exaEsAmount,
            timestamp: token.mou(),
            loanPlanId: _loanPlanId,
            status: 1,
            stakingIds: _stakingIds
        }));

        // send user amount
        require( token.transfer(msg.sender, _loanAmountToTransfer) );

        emit NewLoan(msg.sender, _loanPlanId, _exaEsAmount, _loanInterest, loans[msg.sender].length - 1);
    }

    // repay loan functionality
    function repayLoanSelf(uint256 _loanId) public {
        require(loans[msg.sender][_loanId].status == 1, 'can only repay pending loans');

        require(token.transferFrom(msg.sender, address(this), loans[msg.sender][_loanId].exaEsAmount), 'cannot receive enough tokens, please check if allowance is there');

        loans[msg.sender][_loanId].status = 2;

        // get all stakings associated with this loan.
        // and set next unclaimed months.
        // set status to 1
        // also add to totalActiveStakings
        for(uint256 i = 0; i < loans[msg.sender][_loanId].stakingIds.length; i++) {
            uint256 _stakingId = loans[msg.sender][_loanId].stakingIds[i];

            stakings[msg.sender][_stakingId].status = 1;

            uint256 stakingStartMonth = stakings[msg.sender][_stakingId].timestamp.sub(deployedTimestamp).div(earthSecondsInMonth);

            uint256 stakeEndMonth = stakingStartMonth + stakingPlans[stakings[msg.sender][_stakingId].stakingPlanId].months;

            for(uint256 j = getCurrentMonth() + 1; j <= stakeEndMonth; j++) {
                stakings[msg.sender][_stakingId].isMonthClaimed[i] = false;

                totalActiveStakings[j] = totalActiveStakings[j].add(stakings[msg.sender][_stakingId].exaEsAmount);
            }
        }

    }

    function nomineeWithdraw() public {
        
    }
}
