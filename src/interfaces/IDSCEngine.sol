// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IDSCEngine {
    function depositCollateralAndMintDSC(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToMint
    ) external;

    function depositCollateral(
        address _tokenCollateralAddress,
        uint256 _amountCollateral
    ) external;

    function redeemCollateralForDSC(
        address _tokenCollateralAddress,
        uint256 _amount,
        uint256 _amountDscToBurn
    ) external;

    function redeemCollateral(
        address _tokenCollateralAddress,
        uint256 _amountCollateral
    ) external;

    function mintDSC(uint256 _amountDscToMint) external;

    function burnDSC(uint256 _amount) external;

    function liquidate() external;

    function getHealthFactor() external view;
}
