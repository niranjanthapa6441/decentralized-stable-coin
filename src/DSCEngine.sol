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
    error DSCEngine__AmountProviedShouldBeMoreThanZero(
        uint256 providedAmount,
        string requiredAmount
    );
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCENGINE__TransferFailed();

    /* state variables */
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;

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
        uint256 amount
    );

    /* modifiers */
    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert DSCEngine__AmountProviedShouldBeMoreThanZero({
                providedAmount: _amount,
                requiredAmount: "more than zero"
            });
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
    function depositCollateralAndMintDSC() external override {}

    /**
     *@notice follows CEI
     * @param _tokenCollateralAddress The address of the token to deposit the collateral
     * @param _amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(
        address _tokenCollateralAddress,
        uint256 _amountCollateral
    )
        external
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
            revert DSCENGINE__TransferFailed();
        }
    }

    function redeemCollateralForDSC() external override {}

    function redeemCollateral() external override {}

    /**
     * @notice follows CEI
     * @param _amountDscToMint This is the amount that the user wants to mint DSC
     * @notice they must have more collateral value than the minimum threshold
     */
    function mintDSC(
        uint256 _amountDscToMint
    ) external override moreThanZero(_amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += _amountDscToMint;

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnDSC() external override {}

    function liquidate() external override {}

    function getHealthFactor() external view override {}

    /* Private and Internal view functions */

    function _getAccountInformation(
        address user
    )
        private
        view
        user
        returns (uint56 _totalDscMinted, uint256 collateralValueInUsd)
    {
        _totalDscMinted = s_DSCMinted[user];
        _collateralValueInUsd = getAccountCollateralValueInUsd(user);
    }

    /*
     *Returns how close to liquidation a user is
     * If a use goes below 1, then they can get liquidated
     */
    function _healthFactor(address _user) private view returns (uint256) {
        (
            uint256 _totalDscMinted,
            uint256 _collateralValueInUsd
        ) = _getAccountInformation(_user);
    }

    function _revertIfHealthFactorIsBroken(address _user) internal view {}

    /* Public & External view functions */
    function getAccountCollateralValueInUsd(
        address user
    ) public view returns (uint256 totalCollateralInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralInUsd += getUsdValue(_token, _amount);
        }
        return totalCollateralInUsd;
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) public view retuns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();

        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
}
