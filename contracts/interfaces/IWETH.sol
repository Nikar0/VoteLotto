// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

interface IWETH {
   function deposit() payable external returns(uint256);
   function withdraw(uint256 _amount) external returns(uint256);
}