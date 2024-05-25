// SPDX-License-Identifier: MIT
// Codeak
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

interface _AXIS {
    function totalSupply() external view returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract Alive is ERC20, ERC20Burnable {

    constructor()
        ERC20("AxisAlive", "ALIVE")
    {
        AXIS = _AXIS(0x8BDB63033b02C15f113De51EA1C3a96Af9e8ecb5); // Live AXIS contract address

        launch_time = block.timestamp - (block.timestamp % 86400); // Launch time (first day) is beginning of day constructed

        contractSupplyWei = AXIS.totalSupply(); // Record AXIS total supply, 1,000,000 AXIS (1000000000000000000000000)

        _updateCoreCommunitySupply(0); // Update/initialize first day
    }

    function decimals()
        public view virtual override
        returns (uint8)
    {
        return 18;
    }

    _AXIS private AXIS;

    address private constant burn_address = 0x000000000000000000000000000000000000dEaD;

    address public core_address = 0xe668d27636A844c61557F820F712560A27fEE835;

    uint256 public contractSupplyWei;
    uint256 public coreSupplyWei; // core_address AXIS balance

    uint256 public communitySupplyWei; // Difference between contractSupplyWei and core_address balance
    uint256 public burntCommunitySupplyWei; // Accumulating sum of AXIS sent to burn_address

    uint256 public latestCommunitySupplyDay = 0; // Tracking latest calculated & recorded community supply day
    uint256 public nextCommitmentId = 1; // Next Id to use for new commitment

    uint256 public launch_time; 

    struct CommitmentDetails {
        address committerAddress;
        uint80 commitmentAmountWei; // Max = 1000000000000000000000000
        uint16 committedDays; // Max = 2920
        uint24 startDay; // 16777215 days
        uint24 endedDay; // 16777215 days
        uint96 maxPayout; // Max = (1000000000000000000000000 * 2920) = 2920000000000000000000000000
        uint96 startPayout; // Max = (2920000000000000000000000000 * 0.20)
    }

    mapping(uint256 => uint256) public dayCommunitySupplyWei; // Daily recording of community supply
    mapping(uint256 => uint256) public dayBurntCommunitySupplyWei; // Daily recording of burnt community supply

    mapping(address => uint256[]) public addressActiveCommitmentIds; // List of Addresses Active Commitment Ids
    mapping(address => uint256[]) public addressInactiveCommitmentIds; // List of Addresses Inactive Commitment Ids
    mapping(uint256 => CommitmentDetails) public commitmentIdCommitmentDetails; // Set of CommitmentDetails by commitmentId

    enum CommitmentStatus { Active, Inactive }

    event newStartCommitment(
        uint256 packedData
    );

    event newEndCommitment(
        uint256 packedData
    );

    event newEarlyEndCommitment(
        uint256 commitmentId
    );

    event coreCommunitySupplyUpdated(
        uint256 packedDayData
    );

    event manualCoreCommunitySupplyUpdated(
        uint256 packedDayData
    );

    event coreAddressUpdated(
        address newCoreAddress
    );

    /*
        Get addresses Active or Inactive Commitment Ids length
        Used for pagination
    */
    function getAddressCommitmentIdsLengthByStatus(address _addr, CommitmentStatus status)
        public view
        returns (uint256)
    {
        uint256[] storage commitmentIds;

        if (status == CommitmentStatus.Active) {
            commitmentIds = addressActiveCommitmentIds[_addr];
        } else if (status == CommitmentStatus.Inactive) {
            commitmentIds = addressInactiveCommitmentIds[_addr];
        }
        else {
            return 0;
        }

        return commitmentIds.length;
    }

    /*
        Get paginated array of addresses Active or Inactive Commitment Ids by status
    */
    function getAddressCommitmentIdsPaginatedByStatus(address _addr, uint256 startIndex, uint256 pageSize, CommitmentStatus status)
        public view
        returns (uint256[] memory)
    {
        uint256[] storage commitmentIds;

        if (status == CommitmentStatus.Active) {
            commitmentIds = addressActiveCommitmentIds[_addr];
        } else if (status == CommitmentStatus.Inactive) {
            commitmentIds = addressInactiveCommitmentIds[_addr];
        } else {
            return new uint256[](0);
        }

        if (startIndex >= commitmentIds.length) {
            return new uint256[](0);
        }

        uint256 endIndex = (startIndex + pageSize > commitmentIds.length) ? commitmentIds.length : startIndex + pageSize;
        uint256[] memory commitmentIdsPage = new uint256[](endIndex - startIndex);

        for (uint256 i = startIndex; i < endIndex; i++) {
            commitmentIdsPage[i - startIndex] = commitmentIds[i];
        }

        return commitmentIdsPage;
    }

    function currentDay()
        public view
        returns (uint256)
    {
        return ((block.timestamp - launch_time) / 1 days) + 1; // First day is 1, not 0.
    }

    /*
        Manually update daily records if needed.
    */
    function updateCoreCommunitySupply(uint256 maxDaysToUpdate)
        external
    {
        _updateCoreCommunitySupply(maxDaysToUpdate); 
    }

    /*
        The coreSupplyWei balance and with that communitySupplyWei can change at any time
        Assures daily data, dayCommunitySupplyWei[day] and dayBurntCommunitySupplyWei[day], is easily retrievable for future ending Commitments
        Daily data is recorded once per day, as soon as the current day is greater than the latest community supply day recorded

        Record keeping incentive, must be at least 2 days since last recording and at most 29 done manually with maxDaysToUpdate > 1:
            -Reward Amount = (newBurntCommunitySupplyWei * (2 + ((daysToUpdate - 2) * 10 / 20))) / 100)
            
            -Broken down formula:
                uint256 daysFactor = (daysToUpdate - 2);
                uint256 scaledDaysFactor = (daysFactor * 10 / 20);
                uint256 newSupplyFactor = 2 + scaledDaysFactor;
                uint256 mintAmount = (newBurntCommunitySupplyWei * newSupplyFactor) / 100;
                _mint(msg.sender, mintAmount);

            -Payout Percents:
                When daysToUpdate = 2, 2% of newBurntCommunitySupplyWei
                When daysToUpdate = 3, 2% of newBurntCommunitySupplyWei
                When daysToUpdate = 4, 3% of newBurntCommunitySupplyWei
                When daysToUpdate = 5, 3% of newBurntCommunitySupplyWei
                When daysToUpdate = 6, 4% of newBurntCommunitySupplyWei
                When daysToUpdate = 7, 4% of newBurntCommunitySupplyWei
                ...
                When daysToUpdate = 26, 14% of newBurntCommunitySupplyWei
                When daysToUpdate = 27, 14% of newBurntCommunitySupplyWei
                When daysToUpdate = 28, 15% of newBurntCommunitySupplyWei
                When daysToUpdate = 29, 15% of newBurntCommunitySupplyWei
    */
    function _updateCoreCommunitySupply(uint256 maxDaysToUpdate)
        private
    {
        coreSupplyWei = AXIS.balanceOf(core_address);
        communitySupplyWei = contractSupplyWei - coreSupplyWei;

        uint256 _currentDay = currentDay();
        if (_currentDay > latestCommunitySupplyDay) {
            uint256 daysSinceLast = _currentDay - latestCommunitySupplyDay;
            uint256 daysToUpdate = (daysSinceLast > maxDaysToUpdate && maxDaysToUpdate != 0) ? maxDaysToUpdate : daysSinceLast;

            uint256 newCommunitySupplyWei = communitySupplyWei;
            uint256 newBurntCommunitySupplyWei = burntCommunitySupplyWei;

            for (uint256 i = 1; i <= daysToUpdate; i++) {
                uint256 dayToUpdate = latestCommunitySupplyDay + i;
                dayCommunitySupplyWei[dayToUpdate] = newCommunitySupplyWei;
                dayBurntCommunitySupplyWei[dayToUpdate] = newBurntCommunitySupplyWei;
            }

            latestCommunitySupplyDay += daysToUpdate;

            if (daysToUpdate > 1 && daysToUpdate < 30 && maxDaysToUpdate > 1) {
                _mint(msg.sender, (newBurntCommunitySupplyWei * (2 + ((daysToUpdate - 2) * 10 / 20))) / 100);

                emit manualCoreCommunitySupplyUpdated(
                    uint256(uint16(maxDaysToUpdate))
                    | (uint256(uint16(daysToUpdate)) << 16)
                    | (uint256(uint24(latestCommunitySupplyDay)) << 32)
                    | (uint256(uint80(newBurntCommunitySupplyWei)) << 54)
                );
            }
            else {
                emit coreCommunitySupplyUpdated(
                    uint256(uint16(maxDaysToUpdate))
                    | (uint256(uint16(daysToUpdate)) << 16)
                    | (uint256(uint24(latestCommunitySupplyDay)) << 32)
                );
            }
        }
    }

    /*
        The core_address can change core_address any time
    */
    function updateCoreAddress(address newCoreAddress)
        external
    {
        require(msg.sender == core_address, "ALIVE: Sender is not the core_address");
        require(newCoreAddress != core_address, "ALIVE: new Core Address is the core_address");

        require(AXIS.transferFrom(msg.sender, newCoreAddress, AXIS.balanceOf(msg.sender)), "ALIVE: new core_address Transfer failed");
        core_address = newCoreAddress;

        _updateCoreCommunitySupply(0);
        emit coreAddressUpdated(newCoreAddress);
    }

    /*
        Mints ALIVE for starting a Commitment
        Maximum 2920 days, 8 years
        Commitments require an equal commitment amount in AXIS locked and burnt to create
        Record burntCommunitySupplyWeiBefore so as to not implicate the current Commitment

        availableCommunitySupplyWei represents current non-burnt community supply
        currentToTotalCommunitySupplyRatio represents the distance between the current available community supply and total community supply
            -Linear decline from 1 downward (upscaled 1e18)
        startPayout is 20% of max payout, then dropped further by currentToTotalCommunitySupplyRatio with a combined descale of 1e20 for percentage (100) and 1e18 upscale

    */
    function startCommitment(uint256 commitmentAmountWei, uint256 committedDays)
        external
    {
        require(msg.sender != core_address, "ALIVE: Sender is the core_address");
        require(commitmentAmountWei > 0 && committedDays > 0 && committedDays < 2921, "ALIVE: Invalid parameter");
        require(AXIS.transferFrom(msg.sender, burn_address, commitmentAmountWei), "ALIVE: Burn Transfer failed");
        require(AXIS.transferFrom(msg.sender, address(this), commitmentAmountWei), "ALIVE: Contract Transfer failed");

        uint256 burntCommunitySupplyWeiBefore = burntCommunitySupplyWei;

        burntCommunitySupplyWei += commitmentAmountWei;

        _updateCoreCommunitySupply(0);

        uint256 availableCommunitySupplyWei = communitySupplyWei - burntCommunitySupplyWeiBefore;
        uint256 currentToTotalCommunitySupplyRatio = (availableCommunitySupplyWei * 1e18) / communitySupplyWei;

        uint256 maxPayout = (commitmentAmountWei * committedDays);
        uint256 startPayout = (currentToTotalCommunitySupplyRatio * maxPayout * 20) / 1e20;

        uint256 commitmentId = nextCommitmentId++;
        addressActiveCommitmentIds[msg.sender].push(commitmentId);

        commitmentIdCommitmentDetails[commitmentId] = CommitmentDetails({
             committerAddress: msg.sender
            ,commitmentAmountWei: uint80(commitmentAmountWei)
            ,committedDays: uint16(committedDays)
            ,startDay: uint24(currentDay())
            ,endedDay: uint24(0)
            ,maxPayout: uint96(maxPayout)
            ,startPayout: uint96(startPayout)
        });

        _mint(msg.sender, startPayout);

        emit newStartCommitment(
            uint256(uint80(burntCommunitySupplyWeiBefore))
            | (uint256(uint80(communitySupplyWei)) << 80)
            | (uint256(uint48(commitmentId)) << 160)
        );
    }

    /*
        Let Commitment end early, at a cost
        Requires halfway fulfillment of Commitment days to only get locked Commitment Amount AXIS back, no ALIVE
        Less than halway fulfillment of Commitment days returns nothing, no AXIS no ALIVE
    */
    function earlyEndCommitment(uint256 commitmentIdIndex, uint256 _commitmentId)
        external
    {
        require(msg.sender != core_address, "ALIVE: Sender is the core_address");

        uint256[] storage activeCommitmentIds = addressActiveCommitmentIds[msg.sender];
        require(commitmentIdIndex < activeCommitmentIds.length, "ALIVE: Index out of bounds");

        uint256 commitmentId = activeCommitmentIds[commitmentIdIndex];
        require(_commitmentId == commitmentId, "ALIVE: Assure correct and current commitment");

        CommitmentDetails storage cd = commitmentIdCommitmentDetails[commitmentId];

        uint256 _currentDay = currentDay();
        uint256 finalLockedDay = cd.startDay + cd.committedDays;
        require(_currentDay <= finalLockedDay, "ALIVE: Commitment is already fulfilled");

        _updateCoreCommunitySupply(0);

        activeCommitmentIds[commitmentIdIndex] = activeCommitmentIds[activeCommitmentIds.length - 1];
        activeCommitmentIds.pop();

        addressInactiveCommitmentIds[msg.sender].push(commitmentId);
        cd.endedDay = uint24(_currentDay);

        uint256 halfwayPoint = cd.startDay + ((cd.committedDays + 1) / 2);
        if(_currentDay > halfwayPoint) require(AXIS.transfer(msg.sender, cd.commitmentAmountWei), "ALIVE: Transfer failed");
        else require(AXIS.transfer(core_address, cd.commitmentAmountWei), "ALIVE: Transfer failed");

        emit newEarlyEndCommitment(commitmentId);
    }

    /*
        Mints ALIVE for fulfilling a Commitment
        Can be claimed any day after finalLockedDay

        totalToCurrentCommunitySupplyRatio represents the distance between the total community supply and the current available community supply
            -Exponential incline from 1 upward (upscaled 1e18)

        endPayout is leftover from max payout minus startPayout, then increased further by totalToCurrentCommunitySupplyRatio descaled by 1e18
        Locked Commitment Amount AXIS is returned to the sender
    */
    function endCommitment(uint256 commitmentIdIndex, uint256 _commitmentId)
        external
    {
        require(msg.sender != core_address, "ALIVE: Sender is the core_address");

        uint256[] storage activeCommitmentIds = addressActiveCommitmentIds[msg.sender];
        require(commitmentIdIndex < activeCommitmentIds.length, "ALIVE: Index out of bounds");

        uint256 commitmentId = activeCommitmentIds[commitmentIdIndex];
        require(_commitmentId == commitmentId, "ALIVE: Assure correct and current commitment");

        CommitmentDetails storage cd = commitmentIdCommitmentDetails[commitmentId];

        uint256 finalLockedDay = cd.startDay + cd.committedDays;
        uint256 _currentDay = currentDay();
        require(_currentDay > finalLockedDay, "ALIVE: Commitment is still locked");

        _updateCoreCommunitySupply(0);

        uint256 availableCommunitySupplyWei = dayCommunitySupplyWei[finalLockedDay] - dayBurntCommunitySupplyWei[finalLockedDay];

        uint256 totalToCurrentCommunitySupplyRatio = (dayCommunitySupplyWei[finalLockedDay] * 1e18) / availableCommunitySupplyWei;

        uint256 endPayout = ((cd.maxPayout - cd.startPayout) * totalToCurrentCommunitySupplyRatio) / 1e18;

        activeCommitmentIds[commitmentIdIndex] = activeCommitmentIds[activeCommitmentIds.length - 1];
        activeCommitmentIds.pop();

        addressInactiveCommitmentIds[msg.sender].push(commitmentId);
        cd.endedDay = uint24(_currentDay);

        _mint(msg.sender, endPayout);

        require(AXIS.transfer(msg.sender, cd.commitmentAmountWei), "ALIVE: Transfer failed");

        emit newEndCommitment(
            uint256(uint48(commitmentId))
            | (uint256(uint128(endPayout)) << 48)
        );
    }

}