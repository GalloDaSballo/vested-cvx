// SPDX-License-Identifier: MIT

pragma solidity ^0.6.11;
pragma experimental ABIEncoderV2;

import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/math/MathUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";

import "../interfaces/uniswap/IUniswapRouterV2.sol";
import "../interfaces/badger/ISettV3.sol";
import "../interfaces/badger/IController.sol";
import "../interfaces/cvx/ICvxLocker.sol";
import "../interfaces/snapshot/IDelegateRegistry.sol";

import {BaseStrategy} from "../deps/BaseStrategy.sol";

contract MyStrategy is BaseStrategy {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;
    using SafeMathUpgradeable for uint256;

    // address public want // Inherited from BaseStrategy, the token the strategy wants, swaps into and tries to grow
    address public lpComponent; // Token we provide liquidity with
    address public reward; // Token we farm and swap to want / lpComponent
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant CVX = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;

    address public constant SUSHI_ROUTER =
        0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;

    IDelegateRegistry public constant SNAPSHOT =
        IDelegateRegistry(0x469788fE6E9E9681C6ebF3bF78e7Fd26Fc015446);

    // The address this strategies delegates voting to
    address public constant DELEGATE =
        0xB65cef03b9B89f99517643226d76e286ee999e77;

    bytes32 public constant DELEGATED_SPACE = "cvx.eth";

    ICvxLocker public LOCKER;

    ISettV3 public CVX_VAULT =
        ISettV3(0x53C8E199eb2Cb7c01543C137078a038937a68E40);

    event Debug(string name, uint256 value);

    // Used to signal to the Badger Tree that rewards where sent to it
    event TreeDistribution(
        address indexed token,
        uint256 amount,
        uint256 indexed blockNumber,
        uint256 timestamp
    );

    function initialize(
        address _governance,
        address _strategist,
        address _controller,
        address _keeper,
        address _guardian,
        address[3] memory _wantConfig,
        uint256[3] memory _feeConfig,
        address _locker ///@dev TODO: Add this to deploy
    ) public initializer {
        __BaseStrategy_init(
            _governance,
            _strategist,
            _controller,
            _keeper,
            _guardian
        );

        /// @dev Add config here
        want = _wantConfig[0];
        lpComponent = _wantConfig[1];
        reward = _wantConfig[2];

        performanceFeeGovernance = _feeConfig[0];
        performanceFeeStrategist = _feeConfig[1];
        withdrawalFee = _feeConfig[2];

        LOCKER = ICvxLocker(_locker); //TODO: Make locker hardcoded at top of file

        /// @dev do one off approvals here
        // IERC20Upgradeable(want).safeApprove(gauge, type(uint256).max);
        // Permissions for Locker
        IERC20Upgradeable(CVX).safeApprove(_locker, type(uint256).max);
        IERC20Upgradeable(CVX).safeApprove(
            address(CVX_VAULT),
            type(uint256).max
        );

        // Permissions for Sushiswap
        IERC20Upgradeable(reward).safeApprove(SUSHI_ROUTER, type(uint256).max);

        // Delegate voting to DELEGATE
        SNAPSHOT.setDelegate(DELEGATED_SPACE, DELEGATE);
    }

    /// ===== View Functions =====

    /// @dev Specify the name of the strategy
    function getName() external pure override returns (string memory) {
        return "veCVX Voting Strategy";
    }

    /// @dev Specify the version of the Strategy, for upgrades
    function version() external pure returns (string memory) {
        return "1.0";
    }

    /// @dev Balance of want currently held in strategy positions
    function balanceOfPool() public view override returns (uint256) {
        // Return the balance in locker + unlocked but not withdrawn, better estimate to allow some withdrawals
        return LOCKER.lockedBalanceOf(address(this));

        // TODO: THIS HAS TO BE CHANGED IF WE USE bCVX
    }

    /// @dev Returns true if this strategy requires tending
    function isTendable() public view override returns (bool) {
        return true;
    }

    // @dev These are the tokens that cannot be moved except by the vault
    function getProtectedTokens()
        public
        view
        override
        returns (address[] memory)
    {
        address[] memory protectedTokens = new address[](3);
        protectedTokens[0] = want;
        protectedTokens[1] = lpComponent;
        protectedTokens[2] = reward;
        return protectedTokens;
    }

    /// ===== Permissioned Actions: Governance =====
    /// @notice Delete if you don't need!
    function setKeepReward(uint256 _setKeepReward) external {
        _onlyGovernance();
    }

    /// ===== Internal Core Implementations =====

    /// @dev security check to avoid moving tokens that would cause a rugpull, edit based on strat
    function _onlyNotProtectedTokens(address _asset) internal override {
        address[] memory protectedTokens = getProtectedTokens();

        for (uint256 x = 0; x < protectedTokens.length; x++) {
            require(
                address(protectedTokens[x]) != _asset,
                "Asset is protected"
            );
        }
    }

    /// @dev invest the amount of want
    /// @notice When this function is called, the controller has already sent want to this
    /// @notice Just get the current balance and then invest accordingly
    function _deposit(uint256 _amount) internal override {
        // We receive bCVX -> Convert to bCVX
        CVX_VAULT.withdraw(_amount);

        uint256 toDeposit = IERC20Upgradeable(CVX).balanceOf(address(this));

        // Lock tokens for 16 weeks, send credit to strat, always use max boost cause why not?
        LOCKER.lock(address(this), toDeposit, LOCKER.maximumBoostPayment());
    }

    /// @dev utility function to withdraw everything for migration
    function _withdrawAll() internal override {
        //NOTE: This probably will always fail unless we have all tokens expired
        require(
            LOCKER.lockedBalanceOf(address(this)) ==
                LOCKER.balanceOf(address(this)),
            "Need to wait for complete unlock"
        );

        // Withdraw all we can
        LOCKER.processExpiredLocks(false);

        // Redeposit all into bCVX
        uint256 toDeposit = IERC20Upgradeable(CVX).balanceOf(address(this));

        // Redeposit into bCVX
        CVX_VAULT.deposit(toDeposit);
    }

    /// @dev withdraw the specified amount of want, liquidate from lpComponent to want, paying off any necessary debt for the conversion
    function _withdrawSome(uint256 _amount)
        internal
        override
        returns (uint256)
    {
        // TODO: Convert _amount in bCVX to amount in CVX to unlock and deposit
        uint256 bCVXToCVX = CVX_VAULT.getPricePerFullShare(); // 18 decimals
        emit Debug("bCVXToCVX", bCVXToCVX);

        require(bCVXToCVX > 10**18); // Avoid trying to redeem for less / loss of peg

        uint256 _toWithdraw = _amount.mul(bCVXToCVX).div(10**18);

        // NOTE / TODO: If we own some idle bCVX that is more than _toWithdraw we could
        // just use that
        emit Debug("_toWithdraw", _toWithdraw);

        // Withdrawable
        uint256 withdrawable =
            LOCKER.lockedBalanceOf(address(this)).sub(
                LOCKER.balanceOf(address(this))
            );

        emit Debug("withdrawable", withdrawable);

        // Revert if we have tons locked
        // NOTE: Will let it go through if locker.balanceOf is 0, meaning we have no locked funds
        // NOTE: Rounding errors could make this a little sketch, we run down by 1
        require(
            withdrawable >= _toWithdraw - 1 ||
                LOCKER.balanceOf(address(this)) == 0,
            "Tokens are still locked, please wait"
        );

        // Withdraw all we can
        LOCKER.processExpiredLocks(false);

        uint256 max = IERC20Upgradeable(CVX).balanceOf(address(this));
        emit Debug("max", max);

        CVX_VAULT.deposit(max); // May as well deposit all into bCVX which makes it more liquid?

        //NOTE:
        // Depositing into CVX Vault means we now have a CVX Vault balance which may not be used
        // We could add a key in Harvest / Tend to toggle whether to relock or to just keep as bCVX

        //TODO: CHECK | We still may end up with less (I guess)
        uint256 avail = IERC20Upgradeable(want).balanceOf(address(this));
        emit Debug("avail", avail);

        if (avail < _toWithdraw) {
            return avail;
        }

        return _toWithdraw;
    }

    /// @dev manual function to reinvest
    function reinvest() external whenNotPaused returns (uint256 reinvested) {
        _onlyAuthorizedActors();

        // Withdraw all we can
        LOCKER.processExpiredLocks(false);

        // Redeposit all into bCVX
        uint256 toDeposit = IERC20Upgradeable(CVX).balanceOf(address(this));

        // Redeposit into bCVX
        LOCKER.lock(address(this), toDeposit, LOCKER.maximumBoostPayment());
    }

    /// @dev Harvest from strategy mechanics, realizing increase in underlying position
    function harvest() external whenNotPaused returns (uint256 harvested) {
        _onlyAuthorizedActors();

        uint256 _before = IERC20Upgradeable(want).balanceOf(address(this));

        // Get cvxCRV
        LOCKER.getReward(address(this), false);

        // Swap cvxCRV for want (CVX)
        _swapcvxCRVToWant();

        uint256 earned =
            IERC20Upgradeable(want).balanceOf(address(this)).sub(_before);

        /// @notice Keep this in so you get paid!
        (uint256 governancePerformanceFee, uint256 strategistPerformanceFee) =
            _processPerformanceFees(earned);

        /// @dev Harvest event that every strategy MUST have, see BaseStrategy
        emit Harvest(earned, block.number);

        /// @dev Harvest must return the amount of want increased
        return earned;
    }

    /// @dev Rebalance, Compound or Pay off debt here
    function tend() external whenNotPaused {
        _onlyAuthorizedActors();
        revert(); // TODO: FIGURE OUT
    }

    /// @dev Swap from reward to CVX, then deposit into bCVX vault
    function _swapcvxCRVToWant() internal {
        uint256 toSwap = IERC20Upgradeable(reward).balanceOf(address(this));

        if (toSwap == 0) {
            return;
        }

        // Sushi reward to WETH to want
        address[] memory path = new address[](3);
        path[0] = reward;
        path[1] = WETH;
        path[2] = want;
        IUniswapRouterV2(SUSHI_ROUTER).swapExactTokensForTokens(
            toSwap,
            0,
            path,
            address(this),
            now
        );

        // Deposit into vault
        uint256 toDeposit = IERC20Upgradeable(CVX).balanceOf(address(this));
        if (toDeposit > 0) {
            CVX_VAULT.deposit(toDeposit);
        }
    }

    /// ===== Internal Helper Functions =====

    /// @dev used to manage the governance and strategist fee, make sure to use it to get paid!
    function _processPerformanceFees(uint256 _amount)
        internal
        returns (
            uint256 governancePerformanceFee,
            uint256 strategistPerformanceFee
        )
    {
        governancePerformanceFee = _processFee(
            want,
            _amount,
            performanceFeeGovernance,
            IController(controller).rewards()
        );

        strategistPerformanceFee = _processFee(
            want,
            _amount,
            performanceFeeStrategist,
            strategist
        );
    }

    /// @dev used to manage the governance and strategist fee on earned rewards, make sure to use it to get paid!
    function _processRewardsFees(uint256 _amount, address _token)
        internal
        returns (uint256 governanceRewardsFee, uint256 strategistRewardsFee)
    {
        governanceRewardsFee = _processFee(
            _token,
            _amount,
            performanceFeeGovernance,
            IController(controller).rewards()
        );

        strategistRewardsFee = _processFee(
            _token,
            _amount,
            performanceFeeStrategist,
            strategist
        );
    }
}
