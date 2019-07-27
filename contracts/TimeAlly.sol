pragma solidity 0.5.10;

import './SafeMath.sol';
import './Eraswap.sol';
import './NRTManager.sol';

/*

Potential bugs: this contract is designed assuming NRT Release will happen every month.
There might be issues when the NRT scheduled
- added stakingMonth property in Staking struct

fix withdraw fractionFrom15 luck pool
- done

add loanactive contition to take loan
- done

ensure stakingMonth in the struct is being used every where instead of calculation
- done

remove local variables uncesessary

final the earthSecondsInMonth amount in TimeAlly as well in NRT
*/

/// @author The EraSwap Team
/// @title TimeAlly Smart Contract
/// @dev all require statement
contract TimeAlly {
    using SafeMath for uint256;

    struct Staking {
        uint256 exaEsAmount;
        uint256 timestamp;
        uint256 stakingMonth;
        uint256 stakingPlanId;
        uint256 status; /// @dev 1 => active; 2 => loaned; 3 => withdrawed; 4 => cancelled; 5 => nomination mode
        uint256 loanId;
        uint256 totalNominationShares;
        mapping (uint256 => bool) isMonthClaimed;
        mapping (address => uint256) nomination;
    }

    struct StakingPlan {
        uint256 months;
        uint256 fractionFrom15; /// @dev fraction of NRT released. Alotted to TimeAlly is 15% of NRT
        bool isPlanActive; /// @dev when plan is inactive, new stakings must not be able to select this plan. Old stakings which already selected this plan will continue themselves as per plan.
        bool isLoanAllowed;
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

    uint256 deployedTimestamp;
    address public owner;
    Eraswap public token;
    NRTManager public nrtManager;

    /// @dev 1 Year = 365.242 days for taking care of leap years
    uint256 earthSecondsInMonth = 2629744;
    // uint256 earthSecondsInMonth = 30 * 12 * 60 * 60; /// @dev there was a decision for following 360 day year

    StakingPlan[] public stakingPlans;
    LoanPlan[] public loanPlans;

    // user activity details:
    mapping(address => Staking[]) public stakings;
    mapping(address => Loan[]) public loans;
    mapping(address => uint256) public launchReward;

    /// @dev TimeAlly month to exaEsAmount mapping.
    mapping (uint256 => uint256) public totalActiveStakings;

    /// @notice NRT being received from NRT Manager every month is stored in this array
    /// @dev current month is the length of this array
    uint256[] public timeAllyMonthlyNRT;

    event NewStaking (
        address indexed _userAddress,
        uint256 indexed _stakePlanId,
        uint256 _exaEsAmount,
        uint256 _stakingId
    );

    event NomineeNew (
        address indexed _userAddress,
        uint256 indexed _stakingId,
        address indexed _nomineeAddress
    );

    event NomineeWithdraw (
        address indexed _userAddress,
        uint256 indexed _stakingId,
        address indexed _nomineeAddress,
        uint256 _liquid,
        uint256 _accrued
    );

    event BenefitWithdrawl (
        address indexed _userAddress,
        uint256 _atMonth,
        uint256 _accruedPercentage,
        uint256 _liquidShare,
        uint256 _accruedShare
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
        require(
          msg.sender == address(nrtManager)
          // , 'only NRT manager can call'
        );
        _;
    }

    modifier onlyOwner() {
        require(
          msg.sender == owner
          // , 'only deployer can call'
        );
        _;
    }

    /// @notice sets up TimeAlly contract when deployed
    /// @param _tokenAddress - is EraSwap contract address
    /// @param _nrtAddress - is NRT Manager contract address
    constructor(address _tokenAddress, address _nrtAddress) public {
        owner = msg.sender;
        token = Eraswap(_tokenAddress);
        nrtManager = NRTManager(_nrtAddress);
        deployedTimestamp = token.mou();
        timeAllyMonthlyNRT.push(0); /// @dev first month there is no NRT released
    }

    /// @notice this function is used by NRT manager to communicate NRT release to TimeAlly
    function increaseMonth(uint256 _timeAllyNRT) public onlyNRTManager {
        timeAllyMonthlyNRT.push(_timeAllyNRT);
    }

    /// @notice TimeAlly month is dependent on the monthly NRT release
    /// @return current month is the TimeAlly month
    function getCurrentMonth() public view returns (uint256) {
        return timeAllyMonthlyNRT.length - 1;
    }

    /// @notice this function is used by owner to create plans for new stakings
    /// @param _months - is number of staking months of a plan. for eg. 12 months
    /// @param _fractionFrom15 - NRT fraction (max 15%) benefit to be given to user. rest is sent back to NRT in Luck Pool
    /// @param _isLoanAllowed - Specifies whether loan can be taken on stakings with this plan
    function createStakingPlan(uint256 _months, uint256 _fractionFrom15, bool _isLoanAllowed) public onlyOwner {
        stakingPlans.push(StakingPlan({
            months: _months,
            fractionFrom15: _fractionFrom15,
            isPlanActive: true,
            isLoanAllowed: _isLoanAllowed
        }));
    }

    /// @notice this function is used by owner to create plans for new loans
    /// @param _loanMonths - number of months or duration of loan, loan taker must repay the loan before this period
    /// @param _loanRate - this is total % of loaning amount charged while taking loan, this charge is sent to luckpool in NRT manager which ends up distributed back to the community again
    function createLoanPlan(uint256 _loanMonths, uint256 _loanRate) public onlyOwner {
        loanPlans.push(LoanPlan({
            loanMonths: _loanMonths,
            loanRate: _loanRate
        }));
    }

    /// @notice this function is used by owner to deactivate a existing staking plan or activate a deactivated staking plan for new stakings. Deactivating a staking plan does not affect existing stakings with that plan.
    /// @param _stakingPlanId - the plan which is needed to be activated or deactivated
    function toggleStakingPlan(uint256 _stakingPlanId) public onlyOwner {
        stakingPlans[_stakingPlanId].isPlanActive = !stakingPlans[_stakingPlanId].isPlanActive;
    }

    /// @notice takes ES from user and locks it for a time according to plan selected by user
    /// @param _exaEsAmount - amount of ES tokens (in 18 decimals thats why 'exa') that user wishes to stake
    /// @param _stakingPlanId - plan for staking
    function newStaking(uint256 _exaEsAmount, uint256 _stakingPlanId) public {

        /// @dev 0 ES stakings would get 0 ES benefits and might cause confusions as transaction would confirm but total active stakings will not increase
        require(_exaEsAmount > 0
            // , 'staking amount should be non zero'
        );

        require(stakingPlans[_stakingPlanId].isPlanActive
            // , 'selected plan is not active'
        );

        require(token.transferFrom(msg.sender, address(this), _exaEsAmount)
          // , 'could not transfer tokens'
        );
        uint256 stakeEndMonth = getCurrentMonth() + stakingPlans[_stakingPlanId].months;

        // @dev update the totalActiveStakings array so that staking would be automatically inactive after the stakingPlanMonthhs
        for(
          uint256 month = getCurrentMonth() + 1;
          month <= stakeEndMonth;
          month++
        ) {
            totalActiveStakings[month] = totalActiveStakings[month] + _exaEsAmount;
        }

        stakings[msg.sender].push(Staking({
            exaEsAmount: _exaEsAmount,
            timestamp: token.mou(),
            stakingMonth: getCurrentMonth(),
            stakingPlanId: _stakingPlanId,
            status: 1,
            loanId: 0,
            totalNominationShares: 0
        }));

        emit NewStaking(msg.sender, _stakingPlanId, _exaEsAmount, stakings[msg.sender].length - 1);
    }

    /// @notice this function is used to see total stakings of any user of TimeAlly
    /// @param _userAddress - address of user
    /// @return number of stakings of _userAddress
    function getNumberOfStakingsByUser(address _userAddress) public view returns (uint256) {
        return stakings[_userAddress].length;
    }

    // same as staking(_userAddress, _stakingId)
    // /// @notice view stakes of a user
    // function viewStaking(
    //     address _userAddress,
    //     uint256 _stakingId
    // ) public view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
    //     return (
    //         stakings[_userAddress][_stakingId].exaEsAmount,
    //         stakings[_userAddress][_stakingId].timestamp,
    //         stakings[_userAddress][_stakingId].stakingPlanId,
    //         stakings[_userAddress][_stakingId].status,
    //         // stakings[_userAddress][_stakingId].accruedExaEsAmount,
    //         stakings[_userAddress][_stakingId].loanId,
    //         stakings[_userAddress][_stakingId].totalNominationShares
    //     );
    // }

    /// @notice this function is used to topup reward balance in smart contract. Rewards are transferable. Anyone with reward balance can only claim it as a new staking.
    /// @dev Allowance is required before topup.
    /// @param _exaEsAmount - amount to add to your rewards for sending rewards to others
    function topupRewardBucket(uint256 _exaEsAmount) public {
        require(token.transferFrom(msg.sender, address(this), _exaEsAmount));
        launchReward[msg.sender] = launchReward[msg.sender].add(_exaEsAmount);
    }

    /// @notice this function is used to send rewards to multiple users
    /// @param _addresses - array of address to send rewards
    /// @param _exaEsAmountArray - array of ExaES amounts sent to each address of _addresses with same index
    function giveLaunchReward(address[] memory _addresses, uint256[] memory _exaEsAmountArray) public onlyOwner {
        for(uint256 i = 0; i < _addresses.length; i++) {
            launchReward[msg.sender] = launchReward[msg.sender].sub(_exaEsAmountArray[i]);
            launchReward[_addresses[i]] = launchReward[_addresses[i]].add(_exaEsAmountArray[i]);
        }
    }

    /// @notice this function is used by rewardees to claim their accrued rewards. This is also used by stakers to restake their 50% benefit received as rewards
    /// @param _stakingPlanId - rewardee can choose plan while claiming rewards as stakings
    function claimLaunchReward(uint256 _stakingPlanId) public {
        require(stakingPlans[_stakingPlanId].isPlanActive
            // , 'selected plan is not active'
        );

        require(launchReward[msg.sender] > 0
            // , 'launch reward should be non zero'
        );
        uint256 reward = launchReward[msg.sender];
        launchReward[msg.sender] = 0;

        // @dev logic similar to newStaking function
        uint256 stakeEndMonth = getCurrentMonth() + stakingPlans[_stakingPlanId].months;

        // @dev update the totalActiveStakings array so that staking would be automatically inactive after the stakingPlanMonthhs
        for(
          uint256 month = getCurrentMonth() + 1;
          month <= stakeEndMonth;
          month++
        ) {
            totalActiveStakings[month] = totalActiveStakings[month] + reward; /// @dev reward means locked ES which only staking option
        }

        stakings[msg.sender].push(Staking({
            exaEsAmount: reward,
            timestamp: token.mou(),
            stakingMonth: getCurrentMonth(),
            stakingPlanId: _stakingPlanId,
            status: 1,
            loanId: 0,
            totalNominationShares: 0
        }));

        emit NewStaking(msg.sender, _stakingPlanId, reward, stakings[msg.sender].length - 1);
    }

    /// @notice this function is used to read the NRT array to display data
    /// @return the TimeAlly `NRT array
    function timeAllyMonthlyNRTArray() public view returns (uint256[] memory) {
        return timeAllyMonthlyNRT;
    }

    /// @notice used internally to see if staking is active or not. does not include if staking is claimed.
    /// @param _userAddress - address of user
    /// @param _stakingId - staking id
    /// @param _atMonth - particular month to check staking active
    /// @return true is staking is in correct time frame and also no loan on it
    function isStakingActive(
        address _userAddress,
        uint256 _stakingId,
        uint256 _atMonth
    ) public view returns (bool) {
        //uint256 stakingMonth = stakings[_userAddress][_stakingId].timestamp.sub(deployedTimestamp).div(earthSecondsInMonth);

        return (
            /// @dev _atMonth should be a month after which staking starts
            stakings[_userAddress][_stakingId].stakingMonth + 1 <= _atMonth

            /// @dev _atMonth should be a month before which staking ends
            && stakings[_userAddress][_stakingId].stakingMonth + stakingPlans[ stakings[_userAddress][_stakingId].stakingPlanId ].months >= _atMonth

            /// @dev staking should have active status
            && stakings[_userAddress][_stakingId].status == 1

            /// @dev if _atMonth is _currentMonth, then withdrawal should be allowed only after 30 days interval since staking
            && (
              getCurrentMonth() != _atMonth
              || token.mou() >= stakings[_userAddress][_stakingId].timestamp
                          .add(
                            getCurrentMonth()
                              .sub(stakings[_userAddress][_stakingId].stakingMonth)
                              .mul(earthSecondsInMonth)
                          )
              )
            );
    }

    /// @notice used to count total active stakings of a user
    /// @param _userAddress - address of any user
    /// @param _atMonth - month at which total active stakings need to be known
    /// @return total active stakings of a user
    function userActiveStakingByMonth(address _userAddress, uint256 _atMonth) public view returns (uint256) {
        // calculate user's active stakings amount for this month
        // divide by total active stakings to get the fraction.
        // multiply by the total timeally NRT to get the share and send it to user

        uint256 _currentMonth = getCurrentMonth();
        require(_currentMonth >= _atMonth
          // , 'cannot see future stakings'
        );

        uint256 userActiveStakingsExaEsAmount;

        for(uint256 i = 0; i < stakings[_userAddress].length; i++) {

            // user staking should be active for it to be considered
            if(isStakingActive(_userAddress, i, _atMonth)) {
                userActiveStakingsExaEsAmount = userActiveStakingsExaEsAmount
                    .add(
                      stakings[_userAddress][i].exaEsAmount
                      // .mul(stakingPlans[ stakings[_userAddress][i].stakingPlanId ].fractionFrom15)
                      // .div(15)
                    );
            }
        }

        return userActiveStakingsExaEsAmount;
    }


    // function seeShareForUserByMonth(
    //   address _userAddress
    //   , uint256[] memory _stakingIds
    //   , uint256 _atMonth) public view returns (uint256) {
    //     // calculate user's active stakings amount for this month
    //     // divide by total active stakings to get the fraction.
    //     // multiply by the total timeally NRT to get the share and send it to user
    //
    //     uint256 _currentMonth = getCurrentMonth();
    //     require(_atMonth <= _currentMonth
    //       // , 'cannot see future stakings'
    //     );
    //
    //     if(totalActiveStakings[_atMonth] == 0) {
    //         return 0;
    //     }
    //
    //     uint256 userActiveStakingsExaEsAmount;
    //
    //     for(uint256 i = 0; i < _stakingIds.length; i++) {
    //         StakingPlan memory plan = stakingPlans[ stakings[_userAddress][_stakingIds[i]].stakingPlanId ];
    //
    //         // user staking should be active for it to be considered
    //         if(isStakingActive(_userAddress, _stakingIds[i], _atMonth)
    //           && !stakings[_userAddress][_stakingIds[i]].isMonthClaimed[_atMonth]) {
    //             userActiveStakingsExaEsAmount = userActiveStakingsExaEsAmount.add(
    //               stakings[_userAddress][_stakingIds[i]].exaEsAmount
    //                 .mul(plan.fractionFrom15)
    //                 .div(15)
    //             );
    //         }
    //     }
    //
    //     return userActiveStakingsExaEsAmount.mul(timeAllyMonthlyNRT[_atMonth]).div(totalActiveStakings[_atMonth]);
    // }
    //
    // function withdrawShareForUserByMonth(
    //   uint256[] memory _stakingIds
    //   , uint256 _atMonth
    //   , uint256 _accruedPercentage
    // ) public {
    //     uint256 _currentMonth = getCurrentMonth();
    //
    //     require(_currentMonth >= _atMonth
    //       // , 'cannot withdraw future stakings'
    //     );
    //
    //     if(totalActiveStakings[_currentMonth] == 0) {
    //         require(false
    //           // , 'total active stakings should be non zero'
    //         );
    //     }
    //
    //     require(_accruedPercentage >= 50
    //       // , 'accruedPercentage should be at least 50'
    //     );
    //
    //     uint256 _userTotalEffectiveStakings;
    //     uint256 _userTotalActiveStakings;
    //
    //     for(uint256 i = 0; i < _stakingIds.length; i++) {
    //         StakingPlan memory _plan = stakingPlans[ stakings[msg.sender][_stakingIds[i]].stakingPlanId ];
    //
    //         // user staking should be active for it to be considered
    //         if(isStakingActive(msg.sender, _stakingIds[i], _atMonth)
    //           && !stakings[msg.sender][_stakingIds[i]].isMonthClaimed[_atMonth]) {
    //
    //             // marking user as claimed
    //             stakings[msg.sender][_stakingIds[i]].isMonthClaimed[_atMonth] = true;
    //
    //             _userTotalActiveStakings = _userTotalActiveStakings.add(stakings[msg.sender][_stakingIds[i]].exaEsAmount);
    //
    //             uint256 _effectiveAmount = stakings[msg.sender][_stakingIds[i]].exaEsAmount
    //               .mul(_plan.fractionFrom15).div(15);
    //             _userTotalEffectiveStakings = _userTotalEffectiveStakings.add(_effectiveAmount);
    //
    //             // _luckPool = _luckPool.add(
    //             //   stakings[msg.sender][i].exaEsAmount
    //             //   .mul( uint256(15).sub(_plan.fractionFrom15) ).div(15)
    //             // )
    //             // ;
    //         }
    //     }
    //
    //     uint256 _effectiveBenefit = _userTotalEffectiveStakings
    //                             .mul(timeAllyMonthlyNRT[_atMonth])
    //                             .div(totalActiveStakings[_atMonth]);
    //                             //.mul(100 - _accruedPercentage).div(100);
    //
    //     require(_effectiveBenefit > 0
    //         // , 'transaction should not confirm for 0 effective benefit'
    //     );
    //
    //
    //     uint256 _pseudoBenefit = _userTotalActiveStakings
    //                             .mul(timeAllyMonthlyNRT[_atMonth])
    //                             .div(totalActiveStakings[_atMonth]);
    //
    //     uint256 _luckPool = _pseudoBenefit.sub(_effectiveBenefit);
    //     require( token.transfer(address(nrtManager), _luckPool) );
    //     require( nrtManager.UpdateLuckpool(_luckPool) );
    //
    //     uint256 _accruedBenefit = _effectiveBenefit
    //                             .mul(_accruedPercentage).div(100);
    //
    //     uint256 _liquidBenefit = _effectiveBenefit.sub(_accruedBenefit);
    //
    //     if(_liquidBenefit > 0) {
    //         token.transfer(msg.sender, _liquidBenefit);
    //     }
    //
    //     launchReward[msg.sender] = launchReward[msg.sender].add(_accruedBenefit);
    // }


    /// @notice this function is used for seeing the benefits of a staking of any user
    /// @param _userAddress - address of user
    /// @param _stakingId - staking id
    /// @param _months - array of months user is interested to see benefits.
    /// @return amount of ExaES of benefits of entered months
    function seeBenefitOfAStakingByMonths(
        address _userAddress,
        uint256 _stakingId,
        uint256[] memory _months
    ) public view returns (uint256) {
        uint256 benefitOfAllMonths;
        for(uint256 i = 0; i < _months.length; i++) {
            require(
              isStakingActive(_userAddress, _stakingId, _months[i])
              && !stakings[_userAddress][_stakingId].isMonthClaimed[_months[i]]
              // , 'staking must be active'
            );
            uint256 benefit = stakings[_userAddress][_stakingId].exaEsAmount
                              .mul(timeAllyMonthlyNRT[ _months[i] ])
                              .div(totalActiveStakings[ _months[i] ]);
            benefitOfAllMonths = benefitOfAllMonths.add(benefit);
        }
        return benefitOfAllMonths.mul(
          stakingPlans[stakings[_userAddress][_stakingId].stakingPlanId].fractionFrom15
        ).div(15);
    }

    /// @notice this function is used for withdrawing the benefits of a staking of any user
    /// @param _stakingId - staking id
    /// @param _months - array of months user is interested to withdraw benefits of staking.
    function withdrawBenefitOfAStakingByMonths(
        uint256 _stakingId,
        uint256[] memory _months
    ) public {
        uint256 _benefitOfAllMonths;
        for(uint256 i = 0; i < _months.length; i++) {
            require(
              isStakingActive(msg.sender, _stakingId, _months[i])
              && !stakings[msg.sender][_stakingId].isMonthClaimed[_months[i]]
              // , 'staking must be active'
            );
            uint256 _benefit = stakings[msg.sender][_stakingId].exaEsAmount
                              .mul(timeAllyMonthlyNRT[ _months[i] ])
                              .div(totalActiveStakings[ _months[i] ]);

            _benefitOfAllMonths = _benefitOfAllMonths.add(_benefit);
            stakings[msg.sender][_stakingId].isMonthClaimed[_months[i]] = true;
        }

        uint256 _luckPool = _benefitOfAllMonths
                        .mul( uint256(15).sub(stakingPlans[stakings[msg.sender][_stakingId].stakingPlanId].fractionFrom15) )
                        .div( 15 );

        require( token.transfer(address(nrtManager), _luckPool) );
        require( nrtManager.UpdateLuckpool(_luckPool) );

        _benefitOfAllMonths = _benefitOfAllMonths.sub(_luckPool);

        uint256 _halfBenefit = _benefitOfAllMonths.div(2);
        require( token.transfer(msg.sender, _halfBenefit) );

        launchReward[msg.sender] = launchReward[msg.sender].add(_halfBenefit);
    }


    // function restakeAccrued(uint256 _stakingId, uint256 _stakingPlanId) public {
    //     require(stakings[msg.sender][_stakingId].accruedExaEsAmount > 0);
    //
    //     uint256 _accruedExaEsAmount = stakings[msg.sender][_stakingId].accruedExaEsAmount;
    //     stakings[msg.sender][_stakingId].accruedExaEsAmount = 0;
    //     newStaking(
    //       _accruedExaEsAmount,
    //       _stakingPlanId
    //     );
    // }

    /// @notice this function is used to withdraw the principle amount of multiple stakings which have their tenure completed
    /// @param _stakingIds - input which stakings to withdraw
    function withdrawExpiredStakings(uint256[] memory _stakingIds) public {
        for(uint256 i = 0; i < _stakingIds.length; i++) {
            require(token.mou() >= stakings[msg.sender][_stakingIds[i]].timestamp
                    .add(stakingPlans[ stakings[msg.sender][_stakingIds[i]].stakingPlanId ].months.mul(earthSecondsInMonth))
              // , 'cannot withdraw before staking ends'
            );
            stakings[msg.sender][_stakingIds[i]].status = 3;

            // if(stakings[msg.sender][_stakings[i]].accruedExaEsAmount > 0) {
            //   uint256 accruedExaEsAmount = stakings[msg.sender][_stakings[i]].accruedExaEsAmount;
            //   stakings[msg.sender][_stakings[i]].accruedExaEsAmount = 0;
            //   newStaking(
            //     accruedExaEsAmount,
            //     stakings[msg.sender][_stakings[i]].stakingPlanId
            //   );
            // }

            token.transfer(msg.sender, stakings[msg.sender][_stakingIds[i]].exaEsAmount);
        }
    }

    // function cancelStaking(uint256 _stakingId) public {
    //     require(stakings[msg.sender][_stakingId].status == 1, 'to cansal, staking must be active');
    //
    //     stakings[msg.sender][_stakingId].status = 4;
    //
    //     uint256 _currentMonth = getCurrentMonth();
    //
    //     uint256 stakingStartMonth = stakings[msg.sender][_stakingId].timestamp.sub(deployedTimestamp).div(earthSecondsInMonth);
    //
    //     uint256 stakeEndMonth = stakingStartMonth + stakingPlans[stakings[msg.sender][_stakingId].stakingPlanId].months;
    //
    //     for(uint256 j = _currentMonth + 1; j <= stakeEndMonth; j++) {
    //         totalActiveStakings[j] = totalActiveStakings[j].sub(stakings[msg.sender][_stakingId].exaEsAmount);
    //     }
    //
    //     // logic for 24 month withdraw
    //     stakings[msg.sender][_stakingId].refundMonthClaimedLast = getCurrentMonth();
    //     stakings[msg.sender][_stakingId].refundMonthsRemaining = 24;
    // }
    //
    // function withdrawCancelStaking(uint256 _stakingId) public {
    //     // calculate how much months can be withdrawn and mark it and transfer it to user.
    //
    //     require(stakings[msg.sender][_stakingId].status == 4, 'staking must be cancelled');
    //     require(stakings[msg.sender][_stakingId].refundMonthsRemaining > 0, 'all refunds are claimed');
    //
    //     uint256 _currentMonth = getCurrentMonth();
    //
    //     // the last month to current month would tell months not claimed
    //     // min ( diff, remaining ) must be taken
    //
    //     uint256 _withdrawMonths = _currentMonth.sub(stakings[msg.sender][_stakingId].refundMonthClaimedLast);
    //
    //     if(_withdrawMonths > stakings[msg.sender][_stakingId].refundMonthsRemaining) {
    //         _withdrawMonths = stakings[msg.sender][_stakingId].refundMonthsRemaining;
    //     }
    //
    //     uint256 _amountToTransfer = stakings[msg.sender][_stakingId].exaEsAmount
    //                                   .mul(_withdrawMonths).div(24);
    //
    //     stakings[msg.sender][_stakingId].refundMonthClaimedLast = getCurrentMonth();
    //     stakings[msg.sender][_stakingId].refundMonthsRemaining = stakings[msg.sender][_stakingId].refundMonthsRemaining.sub(_withdrawMonths);
    //
    //     token.transfer(msg.sender, _amountToTransfer);
    //
    // }
    //

    /// @notice this function is used to estimate the maximum amount of loan that any user can take with their stakings
    /// @param _userAddress - address of user
    /// @param _stakingIds - array of staking ids which should be used to estimate max loan amount
    /// @return max loaning amount
    function seeMaxLoaningAmountOnUserStakings(address _userAddress, uint256[] memory _stakingIds) public view returns (uint256) {
        uint256 _currentMonth = getCurrentMonth();
        //require(_currentMonth >= _atMonth, 'cannot see future stakings');

        uint256 userStakingsExaEsAmount;

        for(uint256 i = 0; i < _stakingIds.length; i++) {

            if(isStakingActive(_userAddress, _stakingIds[i], _currentMonth)
              && stakingPlans[ stakings[_userAddress][_stakingIds[i]].stakingPlanId ].isLoanAllowed
              // && !stakings[_userAddress][_stakingIds[i]].isMonthClaimed[_currentMonth]
            ) {
                userStakingsExaEsAmount = userStakingsExaEsAmount
                    .add(stakings[_userAddress][_stakingIds[i]].exaEsAmount
                      // .mul(stakingPlans[ stakings[_userAddress][_stakingIds[i]].stakingPlanId ].fractionFrom15)
                      // .div(15)
                    );
            }
        }

        return userStakingsExaEsAmount.div(2);
            //.mul( uint256(100).sub(loanPlans[_loanPlanId].loanRate) ).div(100);
    }

    /// @notice this function is used to take loan on multiple stakings
    /// @param _loanPlanId - user can select this plan which defines loan duration and loan interest
    /// @param _exaEsAmount - loan amount, this will also be the loan repay amount, the interest will first be deducted from this and then amount will be credited
    /// @param _stakingIds - staking ids user wishes to encash for taking the loan
    function takeLoanOnSelfStaking(uint256 _loanPlanId, uint256 _exaEsAmount, uint256[] memory _stakingIds) public {
        // @dev when loan is to be taken, first calculate active stakings from given stakings array. this way we can get how much loan user can take and simultaneously mark stakings as claimed for next months number loan period
        uint256 _currentMonth = getCurrentMonth();
        uint256 _userStakingsExaEsAmount;

        for(uint256 i = 0; i < _stakingIds.length; i++) {

            if( isStakingActive(msg.sender, _stakingIds[i], _currentMonth)
                && stakingPlans[ stakings[msg.sender][_stakingIds[i]].stakingPlanId ].isLoanAllowed
            ) {

                // @dev store sum in a number
                _userStakingsExaEsAmount = _userStakingsExaEsAmount
                    .add(
                        stakings[msg.sender][ _stakingIds[i] ].exaEsAmount
                );

                // @dev subtract total active stakings
                uint256 stakingStartMonth = stakings[msg.sender][_stakingIds[i]].stakingMonth;

                uint256 stakeEndMonth = stakingStartMonth + stakingPlans[stakings[msg.sender][_stakingIds[i]].stakingPlanId].months;

                for(uint256 j = _currentMonth + 1; j <= stakeEndMonth; j++) {
                    totalActiveStakings[j] = totalActiveStakings[j].sub(_userStakingsExaEsAmount);
                }

                // @dev make stakings inactive
                for(uint256 j = 1; j <= loanPlans[_loanPlanId].loanMonths; j++) {
                    stakings[msg.sender][ _stakingIds[i] ].isMonthClaimed[ _currentMonth + j ] = true;
                    stakings[msg.sender][ _stakingIds[i] ].status = 2; // means in loan
                }
            }
        }

        uint256 _maxLoaningAmount = _userStakingsExaEsAmount.div(2);

        if(_exaEsAmount > _maxLoaningAmount) {
            require(false
              // , 'cannot loan more than maxLoaningAmount'
            );
        }


        uint256 _loanInterest = _exaEsAmount.mul(loanPlans[_loanPlanId].loanRate).div(100);
        uint256 _loanAmountToTransfer = _exaEsAmount.sub(_loanInterest);

        require( token.transfer(address(nrtManager), _loanInterest) );
        require( nrtManager.UpdateLuckpool(_loanInterest) );

        loans[msg.sender].push(Loan({
            exaEsAmount: _exaEsAmount,
            timestamp: token.mou(),
            loanPlanId: _loanPlanId,
            status: 1,
            stakingIds: _stakingIds
        }));

        // @dev send user amount
        require( token.transfer(msg.sender, _loanAmountToTransfer) );

        emit NewLoan(msg.sender, _loanPlanId, _exaEsAmount, _loanInterest, loans[msg.sender].length - 1);
    }

    /// @notice repay loan functionality
    /// @dev need to give allowance before this
    /// @param _loanId - select loan to repay
    function repayLoanSelf(uint256 _loanId) public {
        require(loans[msg.sender][_loanId].status == 1
          // , 'can only repay pending loans'
        );

        require(loans[msg.sender][_loanId].timestamp + loanPlans[ loans[msg.sender][_loanId].loanPlanId ].loanMonths.mul(earthSecondsInMonth) > token.mou()
          // , 'cannot repay expired loan'
        );

        require(token.transferFrom(msg.sender, address(this), loans[msg.sender][_loanId].exaEsAmount)
          // , 'cannot receive enough tokens, please check if allowance is there'
        );

        loans[msg.sender][_loanId].status = 2;

        // @dev get all stakings associated with this loan. and set next unclaimed months. then set status to 1 and also add to totalActiveStakings
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

    /// @notice this function is used to add nominee to a staking
    /// @param _stakingId - staking id
    /// @param _nomineeAddress - address of nominee to be added to staking
    /// @param _shares - amount of shares of the staking to the nominee
    /// @dev shares is compared with total shares issued in a staking to see the percent nominee can withdraw. Nominee can withdraw only after one year past the end of tenure of staking. Upto 1 year past the end of tenure of staking, owner can withdraw principle amount of staking as well as can CRUD nominees. Owner of staking is has this time to withdraw their staking, if they fail to do so, after that nominees are allowed to withdraw. Withdrawl by first nominee will trigger staking into nomination mode and owner of staking cannot withdraw the principle amount as it will be distributed with only nominees and only they can withdraw it.
    function addNominee(uint256 _stakingId, address _nomineeAddress, uint256 _shares) public {
        require(stakings[msg.sender][_stakingId].status == 1
          // , 'staking should active'
        );
        require(stakings[msg.sender][_stakingId].nomination[_nomineeAddress] == 0
          // , 'should not be nominee already'
        );
        stakings[msg.sender][_stakingId].totalNominationShares = stakings[msg.sender][_stakingId].totalNominationShares.add(_shares);
        stakings[msg.sender][_stakingId].nomination[_nomineeAddress] = _shares;
        emit NomineeNew(msg.sender, _stakingId, _nomineeAddress);
    }

    /// @notice this function is used to read the nomination of a nominee address of a staking of a user
    /// @param _userAddress - address of staking owner
    /// @param _stakingId - staking id
    /// @param _nomineeAddress - address of nominee
    /// @return nomination of the nominee
    function viewNomination(address _userAddress, uint256 _stakingId, address _nomineeAddress) public view returns (uint256) {
        return stakings[_userAddress][_stakingId].nomination[_nomineeAddress];
    }

    /// @notice this function is used to update nomination of a nominee of sender's staking
    /// @param _stakingId - staking id
    /// @param _nomineeAddress - address of nominee
    /// @param _shares - shares to be updated for the nominee
    function updateNominee(uint256 _stakingId, address _nomineeAddress, uint256 _shares) public {
        require(stakings[msg.sender][_stakingId].status == 1
          // , 'staking should active'
        );
        uint256 _oldShares = stakings[msg.sender][_stakingId].nomination[_nomineeAddress];
        if(_shares > _oldShares) {
            uint256 _diff = _shares.sub(_oldShares);
            stakings[msg.sender][_stakingId].totalNominationShares = stakings[msg.sender][_stakingId].totalNominationShares.add(_diff);
            stakings[msg.sender][_stakingId].nomination[_nomineeAddress] = stakings[msg.sender][_stakingId].nomination[_nomineeAddress].add(_diff);
        } else if(_shares < _oldShares) {
          uint256 _diff = _oldShares.sub(_shares);
            stakings[msg.sender][_stakingId].nomination[_nomineeAddress] = stakings[msg.sender][_stakingId].nomination[_nomineeAddress].sub(_diff);
            stakings[msg.sender][_stakingId].totalNominationShares = stakings[msg.sender][_stakingId].totalNominationShares.sub(_diff);
        }
    }

    /// @notice this function is used to remove nomination of a address
    /// @param _stakingId - staking id
    /// @param _nomineeAddress - address of nominee
    function removeNominee(uint256 _stakingId, address _nomineeAddress) public {
        require(stakings[msg.sender][_stakingId].status == 1, 'staking should active');
        uint256 _oldShares = stakings[msg.sender][_stakingId].nomination[msg.sender];
        stakings[msg.sender][_stakingId].nomination[_nomineeAddress] = 0;
        stakings[msg.sender][_stakingId].totalNominationShares = stakings[msg.sender][_stakingId].totalNominationShares.sub(_oldShares);
    }

    /// @notice this function is used by nominee to withdraw their share of a staking after 1 year of the end of tenure of staking
    /// @param _userAddress - address of user
    /// @param _stakingId - staking id
    function nomineeWithdraw(address _userAddress, uint256 _stakingId) public {
        // end time stamp > 0
        uint256 currentTime = token.mou();
        require( currentTime > (stakings[_userAddress][_stakingId].timestamp
                    + stakingPlans[stakings[_userAddress][_stakingId].stakingPlanId].months * earthSecondsInMonth
                    + 12 * earthSecondsInMonth )
                    // , 'cannot nominee withdraw before '
                  );

        uint256 _nomineeShares = stakings[_userAddress][_stakingId].nomination[msg.sender];
        require(_nomineeShares > 0
          // , 'Not a nominee of this staking'
        );

        //uint256 _totalShares = ;

        // set staking to nomination mode if it isn't.
        if(stakings[_userAddress][_stakingId].status != 5) {
            stakings[_userAddress][_stakingId].status = 5;
        }

        // adding principal account
        uint256 _pendingLiquidAmountInStaking = stakings[_userAddress][_stakingId].exaEsAmount;
        uint256 _pendingAccruedAmountInStaking;

        // uint256 _stakingStartMonth = stakings[_userAddress][_stakingId].timestamp.sub(deployedTimestamp).div(earthSecondsInMonth);
        uint256 _stakeEndMonth = stakings[_userAddress][_stakingId].stakingMonth + stakingPlans[stakings[_userAddress][_stakingId].stakingPlanId].months;

        // adding monthly benefits which are not claimed
        for(
          uint256 i = stakings[_userAddress][_stakingId].stakingMonth; //_stakingStartMonth;
          i < _stakeEndMonth;
          i++
        ) {
            if( stakings[_userAddress][_stakingId].isMonthClaimed[i] ) {
                uint256 _effectiveAmount = stakings[_userAddress][_stakingId].exaEsAmount
                  .mul(stakingPlans[stakings[_userAddress][_stakingId].stakingPlanId].fractionFrom15)
                  .div(15);
                uint256 _monthlyBenefit = _effectiveAmount
                                          .mul(timeAllyMonthlyNRT[i])
                                          .div(totalActiveStakings[i]);
                _pendingLiquidAmountInStaking = _pendingLiquidAmountInStaking.add(_monthlyBenefit.div(2));
                _pendingAccruedAmountInStaking = _pendingAccruedAmountInStaking.add(_monthlyBenefit.div(2));
            }
        }

        // now we have _pendingLiquidAmountInStaking && _pendingAccruedAmountInStaking
        // on which user's share will be calculated and sent

        // marking nominee as claimed by removing his shares
        stakings[_userAddress][_stakingId].nomination[msg.sender] = 0;

        uint256 _nomineeLiquidShare = _pendingLiquidAmountInStaking
                                        .mul(_nomineeShares)
                                        .div(stakings[_userAddress][_stakingId].totalNominationShares);
        token.transfer(msg.sender, _nomineeLiquidShare);

        uint256 _nomineeAccruedShare = _pendingAccruedAmountInStaking
                                          .mul(_nomineeShares)
                                          .div(stakings[_userAddress][_stakingId].totalNominationShares);
        launchReward[msg.sender] = launchReward[msg.sender].add(_nomineeAccruedShare);

        // emit a event
        emit NomineeWithdraw(_userAddress, _stakingId, msg.sender, _nomineeLiquidShare, _nomineeAccruedShare);
    }
}
