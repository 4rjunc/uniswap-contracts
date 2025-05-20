// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MockToken} from "src/MockToken.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {IPoolInitializer_v4} from "v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {IAllowanceTransfer} from "v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

contract CreatePool is Script {
    function setUp() public {}

    function run() public {
        // Start sending all the following contract calls or transactions as actual on-chain transactions, using a private key.
        vm.startBroadcast();

        ////////////////////////////////////////////// CREATE A POOL & ADD LIQUIDITY //////////////////////////////////////////////
        
        // Create DOGE token (or use existing one if preferred)
        MockToken tokenDOGE = new MockToken("DOGE COIN", "DOGE", 18, 1_000_000_000 ether); // One billion tokens minted
        console.log("DOGE token deployed at: ", address(tokenDOGE));
        
        // Addresses
        address hook = address(0);
        IPositionManager positionManager = IPositionManager(0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4);
        IAllowanceTransfer permit2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
        
        // Pool parameters
        uint24 swapFee = 3000; // 0.30%
        int24 tickSpacing = 60; // Standard tick spacing for 0.30% fee tier
        
        // Position parameters
        uint256 ethAmount = 0.001 ether; // Adjust as needed
        uint256 dogeAmount = 2000 ether; // Adjust as needed
        
        // Use a narrower tick range to concentrate liquidity
        // This will require more tokens for the same liquidity amount
        int24 tickLower = -887220; // A narrower range than full MIN_TICK
        int24 tickUpper = 887220;  // A narrower range than full MAX_TICK
        
        // Ensure ticks are divisible by tickSpacing
        tickLower = tickLower - (tickLower % tickSpacing);
        tickUpper = tickUpper - (tickUpper % tickSpacing);
        
        // Calculate initial price - adjust to use more DOGE tokens
        // This ratio effectively says 1 ETH = 2000 DOGE
        uint160 initialSqrtPriceX96 = encodeSqrtRatioX96(dogeAmount, ethAmount);
        
        // Create the pool key (ensure currency0 < currency1)
        PoolKey memory poolKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO, // ETH
            currency1: Currency.wrap(address(tokenDOGE)), // DOGE token
            fee: swapFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });

        // Step 1: Initialize parameters for multicall
        bytes[] memory multicallParams = new bytes[](2);
        
        // Step 2: Encode pool initialization parameters
        multicallParams[0] = abi.encodeWithSelector(
            IPoolInitializer_v4.initializePool.selector,
            poolKey,
            initialSqrtPriceX96
        );
        
        // Step 3: Initialize mint parameters
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        
        // Calculate the exact amount of liquidity
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            initialSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            ethAmount,
            dogeAmount
        );
        
        console.log("Calculated liquidity amount:", uint256(liquidity));
        
        // Step 4: Encode mint position parameters
        bytes[] memory mintParams = new bytes[](2);
        mintParams[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            liquidity,
            ethAmount, // max amount of ETH
            dogeAmount, // max amount of DOGE
            msg.sender, // recipient of the position
            new bytes(0) // no hook data
        );
        
        // Step 5: Encode SETTLE_PAIR parameters
        mintParams[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        
        // Step 6: Encode modifyLiquidities call
        uint256 deadline = block.timestamp + 3600; // 1 hour deadline
        multicallParams[1] = abi.encodeWithSelector(
            positionManager.modifyLiquidities.selector,
            abi.encode(actions, mintParams),
            deadline
        );
        
        // Step 7: Approve tokens for Permit2 and PositionManager
        // Only approve the exact amount of DOGE tokens needed for this transaction
        IERC20(address(tokenDOGE)).approve(address(permit2), dogeAmount);
        
        // Then approve PositionManager via Permit2 to use only the exact amount needed
        permit2.approve(
            address(tokenDOGE), 
            address(positionManager), 
            uint160(dogeAmount), // only approve the exact amount needed
            uint48(deadline) // use same deadline as above
        );
        
        console.log("About to execute multicall with ETH value:", ethAmount);
        
        // Step 8: Execute the multicall with ETH value
        try positionManager.multicall{value: ethAmount}(multicallParams) {
            console.log("Pool creation and liquidity addition successful!");
        } catch Error(string memory reason) {
            console.log("Transaction failed with reason:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("Transaction failed with no reason string");
        }
        
        vm.stopBroadcast();
    }

    function encodeSqrtRatioX96(uint256 amount1, uint256 amount0) internal pure returns (uint160 sqrtPriceX96) {
        require(amount0 > 0, "PriceMath: division by zero");
        // Multiply amount1 by 2^192 (left shift by 192) to preserve precision after the square root
        uint256 ratioX192 = (amount1 << 192) / amount0;
        uint256 sqrtRatio = Math.sqrt(ratioX192);
        require(sqrtRatio <= type(uint160).max, "PriceMath: sqrt overflow");
        sqrtPriceX96 = uint160(sqrtRatio);
    }
}
