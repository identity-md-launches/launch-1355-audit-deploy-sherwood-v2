// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SherwoodV2, IDiceEntropy} from "src/SherwoodV2.sol";

contract LargeBoardNoDice {
    function getFeeV2(address, uint32) external pure returns (uint128) {
        return 25_000_000_000_000;
    }
}

contract SherwoodV2LargeBoardKingTest is Test {
    uint256 internal constant GENESIS = 1_791_835_200;
    uint160 internal constant PRICE_ONE = 79228162514264337593543950336;

    IPoolManager internal manager;
    PoolSwapTest internal router;
    MockERC20 internal gameToken;
    SherwoodV2 internal game;
    PoolKey internal gameKey;

    receive() external payable {}

    function setUp() public {
        vm.warp(GENESIS + 1);
        address owner = makeAddr("owner");
        manager = new PoolManager(address(this));
        router = new PoolSwapTest(manager);
        PoolModifyLiquidityTest lr = new PoolModifyLiquidityTest(manager);
        gameToken = new MockERC20("Game", "GAME", 18);
        MockERC20 hostToken = new MockERC20("Host", "HOST", 18);
        address hookAddress = address(uint160(0xA11D0000) | uint160(0x20CC));
        deployCodeTo(
            "SherwoodV2.sol:SherwoodV2",
            abi.encode(
                manager,
                Currency.wrap(address(gameToken)),
                Currency.wrap(address(hostToken)),
                uint256(100_000e18),
                IDiceEntropy(address(new LargeBoardNoDice())),
                makeAddr("provider"),
                owner,
                GENESIS
            ),
            hookAddress
        );
        game = SherwoodV2(payable(hookAddress));
        gameKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(gameToken)), 9000, 180, IHooks(hookAddress));
        vm.prank(owner);
        manager.initialize(gameKey, PRICE_ONE);
        gameToken.mint(address(this), 1e30);
        gameToken.approve(address(lr), type(uint256).max);
        vm.deal(address(this), 50_000 ether);
        lr.modifyLiquidity{value: 25_000 ether}(
            gameKey, ModifyLiquidityParams(-59400, 59400, 10_000e18, bytes32(0)), ""
        );
    }

    function _buy(address who, uint256 amount) internal {
        vm.deal(who, who.balance + amount);
        vm.prank(who, who);
        router.swap{value: amount}(
            gameKey,
            SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(uint256(0))
        );
    }

    function _sellAll(address who) internal {
        uint256 amount = gameToken.balanceOf(who);
        vm.startPrank(who, who);
        gameToken.approve(address(router), type(uint256).max);
        router.swap(
            gameKey,
            SwapParams(false, -int256(amount), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
    }

    /// 1,501 players, the leader sells, a 1-point player then plays: the stale cache hands that
    /// player the reign for the rest of the round and the King of the Hill prize, while Bob holds
    /// the top score (90 points) the whole time.
    function test_kingPrizeGoesToTrueLeaderOnLargeBoard() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address carol = makeAddr("carol");
        _buy(alice, 0.1 ether); // 100 points
        _buy(bob, 0.09 ether); // 90 points
        for (uint256 i; i < 1499; ++i) {
            _buy(address(uint160(0x100000 + i)), 0.001 ether); // 1 point each
        }
        vm.warp(GENESIS + 1 hours);
        _sellAll(alice); // alice's points wiped; the cached leader is now stale and n > MAX_LEADER_SCAN
        _buy(carol, 0.001 ether); // 1 point
        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());
        while (!game.settle(0, 200)) {}
        (, address[3] memory top,,,, address king,,,) = game.result(0);
        assertEq(top[0], bob, "bob is #1");
        assertEq(king, bob, "bob held #1 for ~19 hours and must be King; carol (1 point) is crowned instead");
    }
}
