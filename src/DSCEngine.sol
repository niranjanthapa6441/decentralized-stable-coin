// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import {IDSCEngine} from "./interfaces/IDSCEngine.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSC Engine
 * @author Niranjan Thapa
 * 
 * The system is designed to be as minimal as possible, and have the tokens maintain 
   a 1 token == $1 peg.
 * This stable coin has the properties: 
 * - Exogenous Collateral 
 * - Dollar pegged 
 * - Algorithmically Stable 
 * 
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH 
   and WBTC
 * 
 * Our DSC system should always be "overcollateralized". At no point, should the value of all collateral
 < = the $ backed value of all the DSC.
 * 
 * @notice This contract is the core of the Decentralized Stable Coin system. It handles 
   all the logic for minting and redeeming DSC, as well as depositing & withdrawing collateral. 
 * @notice  This contract is very loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is IDSCEngine, ReentrancyGuard {
    /* errors */
    error DSCEngine__AmountProviedShouldBeMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSC__EngineHealthFactorNotImproved();

    /* state variables */
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    /* events */
    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );
    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed to,
        address indexed token,
        uint256 amount
    );
    /* modifiers */
    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert DSCEngine__AmountProviedShouldBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    /* functions */
    constructor(
        address[] memory _tokenAddresses,
        address[] memory _priceFeedAddresses,
        address _dscAddress
    ) {
        if (_tokenAddresses.length != _priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < _tokenAddresses.length; i++) {
            s_priceFeeds[_tokenAddresses[i]] = _priceFeedAddresses[i];
            s_collateralTokens.push(_tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(_dscAddress);
    }

    /* external functions */
    /**
     *
     * @param _tokenCollateralAddress The address of token to deposit as collateral
     * @param _amountCollateral  The amount of collateral to deposit
     * @param _amountDscToMint The amount of decantralized stable coin to mint
     * @notice this function will deposit the collateral and mint the dsc in one transaction
     */
    function depositCollateralAndMintDSC(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToMint
    ) external override {
        depositCollateral(_tokenCollateralAddress, _amountCollateral);
        mintDSC(_amountDscToMint);
    }

    /**
     *
     * @param _tokenCollateralAddress The collateral address to redeeem
     * @param _amountCollateral The amount of collateral to redeem
     * @param _amountDscToBurn The amount of DSC to burn
     * This function burns DSC and redeems underlying collateral in one transaction
     */
    function redeemCollateralForDSC(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToBurn
    ) external override {
        burnDSC(_amountDscToBurn);
        redeemCollateral(_tokenCollateralAddress, _amountCollateral);
    }

    /**
     * 
     * @param _collateral The erc20 collateral address to liquidate from user
     * @param _user The user who has broken the health factor. The _healthFactor should be 
       below MIN_HEALTH_FACTOR 
     * @param _debtToCover The amount of DSC you want to improve the users health factor
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the users fund
     * @notice This function working assumes the protocol will be roughly 200%
       overcollateralized in order for this to work.
     * @notice A bug known would be if the protocol were 100% or less collaterallized, then 
     we wouldn't be able to incentivize the liquidators.
     * For example, if the price of the collateral plummeted before anyone could be liquidated
     *
     * Follows CEI: Checks, Effects, Interactions
     */
    function liquidate(
        address _collateral,
        address _user,
        uint256 _debtToCover
    ) external override moreThanZero(_debtToCover) {
        uint256 startingUserHealthFactor = _healthFactor(_user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            _collateral,
            _debtToCover
        );

        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;
        _redeemCollateral(
            _user,
            msg.sender,
            _collateral,
            totalCollateralToRedeem
        );
        _burnDSC(_user, msg.sender, _debtToCover);
        uint256 endingUserHealthFactor = _healthFactor(_user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSC__EngineHealthFactorNotImproved();
        }
    }

    function getHealthFactor() external view override {}

    /* public functions */
    /**
     *@notice follows CEI
     * @param _tokenCollateralAddress The address of the token to deposit the collateral
     * @param _amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(
        address _tokenCollateralAddress,
        uint256 _amountCollateral
    )
        public
        override
        moreThanZero(_amountCollateral)
        isAllowedToken(_tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][
            _tokenCollateralAddress
        ] += _amountCollateral;
        emit CollateralDeposited(
            msg.sender,
            _tokenCollateralAddress,
            _amountCollateral
        );

        bool success = IERC20(_tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            _amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI
     * @param _amountDscToMint This is the amount that the user wants to mint DSC
     * @notice they must have more collateral value than the minimum threshold
     */
    function mintDSC(
        uint256 _amountDscToMint
    ) public override moreThanZero(_amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += _amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, _amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDSC(uint256 _amount) public override moreThanZero(_amount) {
        _burnDSC(msg.sender, msg.sender, _amount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function redeemCollateral(
        address _tokenCollateralAddress,
        uint256 _amountCollateral
    ) public override moreThanZero(_amountCollateral) nonReentrant {
        _redeemCollateral(
            msg.sender,
            msg.sender,
            _tokenCollateralAddress,
            _amountCollateral
        );
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /* Private and Internal view functions */

    function _getAccountInformation(
        address user
    )
        private
        view
        returns (uint256 _totalDscMinted, uint256 _collateralValueInUsd)
    {
        _totalDscMinted = s_DSCMinted[user];
        _collateralValueInUsd = getAccountCollateralValueInUsd(user);
    }

    /*
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated
     */
    function _healthFactor(address _user) private view returns (uint256) {
        (
            uint256 _totalDscMinted,
            uint256 _collateralValueInUsd
        ) = _getAccountInformation(_user);
        uint256 collateralAdjustedForThreshold = ((_collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION);
        return ((collateralAdjustedForThreshold * PRECISION) / _totalDscMinted);
    }

    function _revertIfHealthFactorIsBroken(address _user) internal view {
        uint256 userHealthFactor = _healthFactor(_user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function _redeemCollateral(
        address _from,
        address _to,
        address _tokenCollateralAddress,
        uint256 _amountCollateral
    ) private {
        s_collateralDeposited[_from][
            _tokenCollateralAddress
        ] -= _amountCollateral;
        emit CollateralRedeemed(
            _from,
            _to,
            _tokenCollateralAddress,
            _amountCollateral
        );

        bool success = IERC20(_tokenCollateralAddress).transfer(
            _to,
            _amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _burnDSC(
        address _onBehalfOf,
        address _dscFrom,
        uint256 _amountDSCToBurn
    ) private {
        s_DSCMinted[_onBehalfOf] -= _amountDSCToBurn;
        bool success = i_dsc.transferFrom(
            _dscFrom,
            address(this),
            _amountDSCToBurn
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(_amountDSCToBurn);
    }

    /* Public & External view functions */

    function getTokenAmountFromUsd(
        address _token,
        uint256 _usdAmountInWei
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[_token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return
            (_usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValueInUsd(
        address user
    ) public view returns (uint256 totalCollateralInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address _token = s_collateralTokens[i];
            uint256 _amount = s_collateralDeposited[user][_token];
            totalCollateralInUsd += getUsdValue(_token, _amount);
        }
        return totalCollateralInUsd;
    }

    function getUsdValue(
        address _token,
        uint256 _amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[_token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();

        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * _amount) /
            PRECISION;
    }
}
