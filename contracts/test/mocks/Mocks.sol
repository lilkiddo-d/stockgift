// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOracleAdapter} from "../../src/interfaces/IStockgift.sol";

/// @notice Test-only ERC-20 (also used as the mock $GIFT project token in tests — never deployed).
contract MockERC20 is ERC20 {
    uint8 internal immutable _dec;

    constructor(string memory name_, string memory symbol_, uint8 dec_) ERC20(name_, symbol_) {
        _dec = dec_;
    }

    function decimals() public view virtual override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @notice Takes a 1% cut on every transfer.
contract FeeOnTransferERC20 is MockERC20 {
    constructor() MockERC20("Fee Token", "FOT", 18) {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 cut = value / 100;
            super._update(from, address(0xdead), cut);
            super._update(from, to, value - cut);
        } else {
            super._update(from, to, value);
        }
    }
}

contract MockAggregator {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint256 public startedAt;

    constructor(uint8 dec_, int256 answer_) {
        decimals = dec_;
        answer = answer_;
        updatedAt = block.timestamp;
        startedAt = block.timestamp;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setStartedAt(uint256 s) external {
        startedAt = s;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, updatedAt, 1);
    }
}

/// @notice Minimal SwapRouter02.exactInput stand-in: prices with an oracle and applies a haircut.
contract MockSwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    IOracleAdapter public oracle;
    uint256 public haircutBps; // execution worse than oracle by this much

    constructor(address oracle_) {
        oracle = IOracleAdapter(oracle_);
    }

    function setHaircutBps(uint256 bps) external {
        haircutBps = bps;
    }

    function exactInput(ExactInputParams calldata p) external payable returns (uint256 amountOut) {
        address tokenIn = address(bytes20(p.path[0:20]));
        address tokenOut = address(bytes20(p.path[p.path.length - 20:]));
        IERC20(tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        amountOut = (oracle.quote(tokenIn, tokenOut, p.amountIn) * (10_000 - haircutBps)) / 10_000;
        require(amountOut >= p.amountOutMinimum, "Too little received");
        MockERC20(tokenOut).mint(p.recipient, amountOut);
    }
}
