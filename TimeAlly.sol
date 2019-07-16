pragma solidity ^0.5.10;

import './SafeMath.sol';
import './Eraswap.sol';

contract TimeAlly {

    using SafeMath for uint256;

    struct Staking {
        uint256 exaEsAmount;
        uint256 timestamp;
        uint256 stakingPlanId;
        uint256 status;
        uint256 accruedExaEsAmount;
        uint256 loanId;
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
        uint256 stakingId;
    }

    struct LoanPlan {
        uint256 loanPeriod;
        uint256 loanRate;
    }


    address public owner;
    address public nrtAddress;
    Eraswap public token;

    uint256 deployedTimestamp;
    uint256 earthSecondsInMonth = 2629744;

    //uint256 public currentMonth;
    uint256[] public timeAllyMonthlyNRT; //current month is the length of this array

    // if StakePlan has only one member then make it uint256[]
    StakingPlan[] public stakingPlans;
    LoanPlan[] public loanPlans;

    // user activity details:
    mapping(address => Staking[]) stakings;
    mapping(address => Loan[]) loans;
    mapping(address => mapping (uint256 => bool)) monthClaim;

    mapping (uint256 => uint256) public totalActiveStakings;

    event NewStaking(
        address indexed _staker,
        uint256 indexed _stakePlanId,
        uint256 _exaEsAmount
    );

    modifier onlyNRTManager() {
        require(msg.sender == nrtAddress, 'only NRT manager can call');
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, 'only deployer can call');
        _;
    }

    constructor(address _tokenAddress, address _nrtAddress) public {
        owner = msg.sender;
        token = Eraswap(_tokenAddress);
        nrtAddress = _nrtAddress;
        deployedTimestamp = token.mou();
        timeAllyMonthlyNRT.push(0);
        timeAllyMonthlyNRT.push(0);
    }

    function increaseMonth(uint256 _timeAllyNRT) public onlyNRTManager() {
        timeAllyMonthlyNRT.push(_timeAllyNRT);
    }

    function getCurrentMonth() public view returns (uint256) {
        return timeAllyMonthlyNRT.length - 2;
    }

    function createStakingPlan(uint256 _months, uint256 _fractionFrom15) public onlyOwner() {
        stakingPlans.push(StakingPlan({
            months: _months,
            fractionFrom15: _fractionFrom15
        }));
    }

    // takes ES from user and locks it for a time
    function newStaking(uint256 _exaEsAmount, uint256 _stakingPlanId) public {
        require(token.transferFrom(msg.sender, address(this), _exaEsAmount), 'could not transfer tokens');
        uint256 stakeEndMonth = getCurrentMonth() + 2 + stakingPlans[_stakingPlanId].months;

        // update the array so that staking would be automatically inactive after the stakingPlanMonthhs
        for(
          uint256 month = getCurrentMonth() + 2;
          month < stakeEndMonth;
          month++
        ) {
            totalActiveStakings[month] = totalActiveStakings[month] + _exaEsAmount;
        }

        Staking[] storage userStakingsArray = stakings[msg.sender];
        userStakingsArray.push(Staking({
            exaEsAmount: _exaEsAmount,
            timestamp: token.mou(),
            stakingPlanId: _stakingPlanId,
            status: 1,
            accruedExaEsAmount: 0,
            loanId: 0
        }));

        emit NewStaking(msg.sender, _stakingPlanId, _exaEsAmount);
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

        function seeShareForCurrentMonthByUser(address _userAddress) public view returns (uint256) {
        // calculate user's active stakings amount for this month
        // divide by total active stakings to get the fraction.
        // multiply by the total timeally NRT to get the share and send it to user
        uint256 month = getCurrentMonth();

        if(totalActiveStakings[month] == 0) {
            return 0;
        }

        uint256 userActiveStakingsExaEsAmount;

        for(uint256 i = 0; i < stakings[_userAddress].length; i++) {
            StakingPlan memory plan = stakingPlans[ stakings[_userAddress][i].stakingPlanId ];

            // user staking should be active for it to be considered
            if(token.mou() - stakings[_userAddress][i].timestamp < plan.months * earthSecondsInMonth) {
                userActiveStakingsExaEsAmount = userActiveStakingsExaEsAmount.add(stakings[_userAddress][i].exaEsAmount.mul(plan.fractionFrom15).div(15));
            }
        }

        return userActiveStakingsExaEsAmount.mul(timeAllyMonthlyNRT[month]).div(totalActiveStakings[month]);
    }


    function seeShareForUserByMonth(address _userAddress, uint256 _month) public view returns (uint256) {
        // calculate user's active stakings amount for this month
        // divide by total active stakings to get the fraction.
        // multiply by the total timeally NRT to get the share and send it to user

        if(totalActiveStakings[_month] == 0) {
            return 0;
        }

        uint256 userActiveStakingsExaEsAmount;

        for(uint256 i = 0; i < stakings[_userAddress].length; i++) {
            StakingPlan memory plan = stakingPlans[ stakings[_userAddress][i].stakingPlanId ];

            // user staking should be active for it to be considered
            if(deployedTimestamp + _month * earthSecondsInMonth - stakings[_userAddress][i].timestamp <= plan.months * earthSecondsInMonth) {
                userActiveStakingsExaEsAmount = userActiveStakingsExaEsAmount.add(stakings[_userAddress][i].exaEsAmount.mul(plan.fractionFrom15).div(15));
            }
        }

        return userActiveStakingsExaEsAmount.mul(timeAllyMonthlyNRT[_month]).div(totalActiveStakings[_month]);
    }


    function withdrawShareForCurrentMonth() public {

        uint256 month = getCurrentMonth();

        require(!monthClaim[msg.sender][month], 'cannot claim again');
        monthClaim[msg.sender][month] = true;

        if(totalActiveStakings[month] == 0) {
            require(false, 'total active stakings should be non zero');
        }

        uint256 userActiveStakingsExaEsAmount;
        uint256 accruedPercentage = 50;

        for(uint256 i = 0; i < stakings[msg.sender].length; i++) {
            StakingPlan memory plan = stakingPlans[ stakings[msg.sender][i].stakingPlanId ];

            // user staking should be active for it to be considered
            if(token.mou() - stakings[msg.sender][i].timestamp < plan.months * earthSecondsInMonth
                && stakings[msg.sender][i].status == 1) {
                // for every staking, incrementing its accrued amount
                uint256 effectiveAmount = stakings[msg.sender][i].exaEsAmount.mul(plan.fractionFrom15).div(15);
                uint256 accruedShare = effectiveAmount.mul(accruedPercentage).div(100);
                stakings[msg.sender][i].accruedExaEsAmount = stakings[msg.sender][i].accruedExaEsAmount.add(accruedShare);

                userActiveStakingsExaEsAmount = userActiveStakingsExaEsAmount.add(effectiveAmount);
            }
        }

        uint256 liquidShare = userActiveStakingsExaEsAmount
                                .mul(timeAllyMonthlyNRT[month])
                                .div(totalActiveStakings[month])
                                .mul(100 - accruedPercentage).div(100);

        if(liquidShare > 0) {
            token.transfer(msg.sender, liquidShare);
        }
    }

    // give in input which which stakings to withdeaw
    function withdrawExpiredStakings(uint256[] memory _stakings) public {
        for(uint256 i = 0; i < _stakings.length; i++) {
            stakings[msg.sender][_stakings[i]].status = 3;

            newStaking(
              stakings[msg.sender][_stakings[i]].accruedExaEsAmount,
              stakings[msg.sender][_stakings[i]].stakingPlanId
            );

            token.transfer(msg.sender, stakings[msg.sender][_stakings[i]].exaEsAmount);
        }
    }

    function consolelog() public view returns (uint256[] memory) {
        return timeAllyMonthlyNRT;
    }


    // Loan Function
    function addLoan(
        uint256 _stakingId,
        uint32 loanperiod,
        uint128 loanamount
        )
        external
        onlyOwner()
        returns(bool)
    {
        Loan memory loan;
        loan.loanPeriod = loanperiod;
        loan.loanAmount = uint128(loanamount);
        loan.loanStartTime = uint32(now);
        loan.loanListIndex = uint32((loanList.push(_stakingId)).sub(1));
        loans[_stakingId] = loan;
        return true;
    }

    function removeLoan(uint256 _stakingId)
        external
        onlyOwner()
        returns(bool)
    {
        require(deleteLoanListElement(loans[_stakingId].loanListIndex));
        return true;
    }
}


