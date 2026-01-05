// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICOGTreasury {
    enum RedemptionType { FULL, PARTIAL }

    event Deposit(address indexed from, uint256 amount);
    event Redemption(address indexed holder, uint256 tokensRedeemed, uint256 stablecoinsOut, RedemptionType redemptionType);

    function stablecoin() external view returns (address);
    function token() external view returns (address);
    function redemptionHaircut() external view returns (uint256);
    function nav() external view returns (uint256);
    function redeem(uint256 tokenAmount) external;
    function redeemAll() external;
    function deposit(uint256 amount) external;
    function activeProposal() external view returns (bool);
}
