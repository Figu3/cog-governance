// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ICOGToken is IERC20 {
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event Redemption(address indexed holder, uint256 tokens, uint256 stablecoinsReceived, bool isPartial);

    function delegate(address delegatee) external;
    function undelegate() external;
    function getDelegatedPower(address delegate_) external view returns (uint256);
    function getEffectiveVotingPower(address account) external view returns (uint256);
    function delegates(address holder) external view returns (address);
    function delegatedPower(address delegate_) external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}
