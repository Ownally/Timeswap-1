pragma solidity >=0.6.0;

interface IERC20 {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);
}

interface InterfaceTimeToken {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);
    
    function debtOf(address owner) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);
}

interface TimeswapCallee {
    function timeswapCall(address sender, uint256 presentOut, uint256 futureOut, bytes calldata data) external;
}

library SafeMathUint256 {
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x, "SafeMathUint256: Add Overflow");
    }
    
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x, "SafeMathUint256: Sub Overflow");
    }
    
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x, "SafeMathUint256: Mul Overflow");
    }
    
    function div(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y > 0, "SafeMathUint256: Div Overflow");
        z = x / y;
    }
}

contract Timeswap {
    using SafeMathUint256 for uint256;

    
    // CONSTANT 
    
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes("transfer(address,uint256)")));
    
    address private constant _factory = address(0);
    address private constant _presentToken = address(0);
    address private constant _futureToken = address(0);
    uint16 private constant _maturityDate = 0;
    uint256 constant MATURITY_TIME = 1593561600;
    
    // MODEL
    
    uint112 private _tokenReserve;
    uint112 private _equityReserve;
    uint32 private _blockTimestampLast;
    
    uint256 private _priceCumulativeLast;
    uint256 private _invariance;
    
    // EVENT 
    
    // UPDATE
    
    function receive(uint256 presentOut, address to, bytes calldata data) external {
        require(block.timestamp >= MATURITY_TIME, "Timeswap: NOT MATURE");
        require(presentOut > 0, "Timeswap: Insufficient Output");
        (uint256 tokenReserve,,,) = reserves();
        require(presentOut <= tokenReserve);
        
        uint256 tokenBalance;
        uint256 equityBalance;
        {
        address presentToken = _presentToken;
        require(to != presentToken, "Timeswap: Invalid To");
        if (presentOut > 0) _safeTransfer(presentToken, to, presentOut); // optimistically transfer tokens
        }
    }
    
    function swap(uint256 presentOut, uint256 futureOut, address to, bytes calldata data) external {
        require(presentOut > 0 || futureOut > 0, "Timeswap: Insufficient Output");
        (uint256 tokenReserve, uint256 equityReserve, uint256 interestReserve,) = reserves();
        require(presentOut < tokenReserve && futureOut < tokenReserve.add(interestReserve), "Timeswap: Insufficient Reserve");
        
        uint256 tokenBalance;
        uint256 equityBalance;
        {
        address presentToken = _presentToken;
        address futureToken = _futureToken;
        require(to != presentToken && to != futureToken, "Timeswap: Invalid To");
        if (presentOut > 0) _safeTransfer(presentToken, to, presentOut); // optimistically trasfer tokens
        if (futureOut > 0) _safeTransfer(futureToken, to, futureOut); // optimistically transfer tokens
        if (data.length > 0) TimeswapCallee(to).timeswapCall(msg.sender, presentOut, futureOut, data);
        tokenBalance = IERC20(presentToken).balanceOf(address(this));
        uint256 balance = InterfaceTimeToken(futureToken).balanceOf(address(this));
        uint256 debt = InterfaceTimeToken(futureToken).debtOf(address(this));
        equityBalance = debt == 0 ? tokenBalance.add(balance) : tokenBalance.sub(debt);
        }
        uint256 presentIn = tokenBalance > tokenReserve - presentOut ? tokenBalance - (tokenReserve - presentOut) : 0;
        uint256 futureIn = equityBalance > equityReserve + presentIn - futureOut ? equityBalance + presentOut - (interestReserve + presentIn - futureOut) : 0;
        require(presentIn > 0 || futureIn > 0, "Timeswap: Insufficient Input");
        {
        uint256 _presentOut = presentOut;
        uint256 interestBalance = interestReserve.add(futureIn).sub(futureOut);
        uint256 interestAdjusted = interestBalance.mul(10).sub(futureIn.sub(_presentOut).mul(3));
        require(tokenBalance.mul(interestAdjusted) >= _invariance.mul(10), "Timeswap: Constant Product");
        }
        
        _update(tokenBalance, equityBalance, tokenReserve, interestReserve);
    }
    
    
 
    
    // VIEW  
    
    function reserves() public view returns (uint256 tokenReserve, uint256 equityReserve, uint256 interestReserve, uint32 blockTimestampLast) {
        tokenReserve = uint256(_tokenReserve);
        equityReserve = uint256(_equityReserve);
        interestReserve = _invariance.div(tokenReserve);
        blockTimestampLast = _blockTimestampLast;
    }
    
    // HELPER
    
    function _update(uint256 tokenBalance, uint256 equityBalance, uint256 tokenReserve, uint256 interestReserve) private {
        require(tokenBalance <= uint112(-1) && equityBalance <= uint112(-1), "Timeswap: Overflow");
        uint32 blockTimestamp = uint32(block.timestamp % (2**32));
        uint32 timeElapsed = blockTimestamp - _blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && tokenReserve != 0 && interestReserve != 0) {
            // never overflows
            // overflow is desired
            _priceCumulativeLast += interestReserve / tokenReserve * timeElapsed; // FIX must be interest insted of equity 
        }
        _tokenReserve = uint112(tokenBalance);
        _equityReserve = uint112(equityBalance);
        _blockTimestampLast = blockTimestamp;
    }
    
    function _safeTransfer(address token, address to, uint256 value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Timeswap: Transfer Failed");
    }
    
}
