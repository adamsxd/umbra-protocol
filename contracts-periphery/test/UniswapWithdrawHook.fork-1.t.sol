// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "test/utils/DSTestPlus.sol";
import "test/utils/DeployUmbraTest.sol";
import "src/UniswapWithdrawHook.sol";

interface IUmbra {
    function sendToken(
    address receiver,
    address tokenAddr,
    uint256 amount,
    bytes32 pkx,
    bytes32 ciphertext
  ) external payable;

    function withdrawTokenAndCall(
    address _acceptor,
    address _tokenAddr,
    IUmbraHookReceiver _hook,
    bytes memory _data
  ) external;
}

interface IUmbraHookReceiver {
  /**
   * @notice Method called after a user completes an Umbra token withdrawal
   * @param _amount The amount of the token withdrawn _after_ subtracting the sponsor fee
   * @param _stealthAddr The stealth address whose token balance was withdrawn
   * @param _acceptor Address where withdrawn funds were sent; can be this contract
   * @param _tokenAddr Address of the ERC20 token that was withdrawn
   * @param _sponsor Address which was compensated for submitting the withdrawal tx
   * @param _sponsorFee Amount of the token that was paid to the sponsor
   * @param _data Arbitrary data passed to this hook by the withdrawer
   */
  function tokensWithdrawn(
    uint256 _amount,
    address _stealthAddr,
    address _acceptor,
    address _tokenAddr,
    address _sponsor,
    uint256 _sponsorFee,
    bytes memory _data
  ) external;
}

contract UniswapWithdrawHookTest is DeployUmbraTest {
  using SafeERC20 for IERC20;
  UniswapWithdrawHook withdrawHook;

  IUmbra umbraContract;
  ISwapRouter swapRouter;
  IERC20 dai;

  uint256 toll;
  // address feeReceiver = address(0x202206);

  // Mainnet Addresses
  address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
  address public constant WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
  address public constant Router = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
  uint24 poolFee = 3000;

  function setUp() override public {
    super.setUp();
    umbraContract = IUmbra(address(umbra));
    swapRouter = ISwapRouter(Router);
    withdrawHook = new UniswapWithdrawHook(ISwapRouter(swapRouter));
    dai = IERC20(DAI);
    // Owner approves tokens
    withdrawHook.approveToken(dai);
    deal(address(DAI), address(this), 1e7 ether);
  }

  function testFuzz_HookTest(uint256 amount, uint256 swapAmount, uint256 feeBips, address feeReceiver) public {
    amount = bound(amount, 0.01 ether, 10e21);
    swapAmount = bound(swapAmount, 0.01 ether, amount);
    feeBips = bound(feeBips, 1, 100);
    dai.approve(address(umbraContract), amount);


    umbraContract.sendToken{value: toll}(address(alice), address(DAI), amount, pkx, ciphertext);

    vm.startPrank(alice); // Withdraw as Alice
    address destinationAddr = bob;
    uint256 minOut;
    IUmbraHookReceiver receiver = IUmbraHookReceiver(address(withdrawHook));

    bytes memory _path = abi.encodePacked(address(DAI), poolFee, WETH9);

    ISwapRouter.ExactInputParams memory params;
    params =
      ISwapRouter.ExactInputParams({
        path: _path,
        recipient : address(swapRouter),
        amountIn : swapAmount,
        amountOutMinimum: minOut
      });

    bytes[] memory multicallData = new bytes[](2);
    multicallData[0] = abi.encodeCall(swapRouter.exactInput, params);
    // params.amountOutMinimum might need to be a different value
    multicallData[1] = abi.encodeCall(swapRouter.unwrapWETH9WithFee, (params.amountOutMinimum, destinationAddr, feeBips, feeReceiver));

    bytes memory data = abi.encode(destinationAddr, multicallData);

    vm.expectCall(umbra, abi.encodeWithSelector(umbraContract.withdrawTokenAndCall.selector));
    vm.expectCall(address(withdrawHook), abi.encodeWithSelector(withdrawHook.tokensWithdrawn.selector));

    umbraContract.withdrawTokenAndCall(address(withdrawHook), address(DAI), receiver, data);

    assertEq(IERC20(DAI).balanceOf(address(bob)), amount-swapAmount);
    assertTrue(feeReceiver.balance > 0);
    assertTrue(address(destinationAddr).balance > minOut);
  }
}