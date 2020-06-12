pragma solidity >=0.6.5;

interface IERC20 {
    // EVENT 
    
    event Approval(address indexed _owner, address indexed _spender, uint _value);
    event Transfer(address indexed _from, address indexed _to, uint _value);
    
    // VIEW 
    
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address _owner) external view returns (uint256);
    function allowance(address _owner, address _spender) external view returns (uint256);

    // UPDATE

    function approve(address _spender, uint256 _value) external returns (bool);
    function transfer(address _to, uint256 _value) external returns (bool);
    function transferFrom(address _from, address _to, uint256 _value) external returns (bool);
}

interface ITimeswapToken is IERC20 {
    // VIEW 
    
    function timeswapFactory() external view returns (address);
    function debtOf(address _owner) external view returns (uint256);
    
    // UPDATE 

    function initialize(string memory _name, string memory _symbol, uint8 _decimals) external;
    function transferWith(address from, address _to, uint256 _value, bytes calldata _data) external returns (bool);
}

interface ITimeswapFactory {
    // VIEW 
    
    function timeswapPool() external view returns (address);
    function timeswapCollateral() external view returns (address);
}

interface ITimeFlashCallee {
    // UPDATE 
    
    function timeFlashCall(address _sender, uint256 _value, bytes calldata _data) external;
}

interface ITimeswapCollateral {
    // VIEW 
    
    function checkCollateral(address _owner, uint256 _debt) external view returns (bool);
}


// may use Open Zeppelin
library SafeMathUint256 {
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x, "SafeMathUint256: Add Overflow");
    }
    
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x, "SafeMathUint256: Sub Overflow");
    }
}

// may use Open Zeppelin
library SafeMathInt256 {
    function add(int256 x, int256 y) internal pure returns (int256 z) {
        z = x + y;
        require((y >= 0 && z >= x) || (y < 0 && z < x), "SafeMathInt256: Add Overflow");
    }
    
    function sub(int256 x, int256 y) internal pure returns (int256 z) {
        z = x - y;
        require((y >= 0 && z <= x) || (y < 0 && z > x), "SafeMathInt256: Sub Overflow");
    }
    
    function negate(int256 x) internal pure returns (int256 y) {
        require(x != -2**255, "Timeswap: Mul Overflow");
        
        y = x * (-1);
    }
}

contract TimeswapToken is ITimeswapToken {
    using SafeMathUint256 for uint256;
    using SafeMathInt256 for int256;
    
    // CONSTANT 
    
    address immutable TIMESWAP_FACTORY;

    // MODEL
    
    string _name;
    string _symbol;
    uint8 _decimals;
    
    uint256 _totalSupply;
    
    mapping(address => int256) _balanceOf;
    mapping(address => mapping(address => uint256)) _allowance;
    
    // INIT
    
    // timeswap factory creates timeswap token contracts of different maturity dates
    constructor() public {
        TIMESWAP_FACTORY = msg.sender;
    }
    
    // EVENT 
    
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Transfer(address indexed from, address indexed to, uint256 value);
    
    // UPDATE
    
    // Called only once by Timeswap Factory
    // Pulled out from constructor maybe to save gas
    // The name could be "Time Dai 18-06-2020"
    // The symbol could be "TDai-18-06-2020"
    // The decimals should be the same decimal as underlying token
    function initialize(string memory name, string memory symbol, uint8 decimals) external override {
        require(msg.sender == TIMESWAP_FACTORY, "Timswap Token: Forbidden");
        _name = name;
        _symbol = symbol;
        _decimals = decimals;
    }
    
    function approve(address spender, uint256 value) external override returns (bool) {
        require(spender != address(0), "Timeswap Token: Zero Address");
        _allowance[msg.sender][spender] = value;
        
        emit Approval(msg.sender, spender, value);
        
        return true;
    }
    
    function transfer(address to, uint256 value) external override returns (bool) {
        _transfer(msg.sender, to, value, new bytes(0));
        
        return true;
    }
    
    function transferFrom(address from, address to, uint256 value) external override returns (bool) {
        if (_allowance[from][msg.sender] != uint(-1)) {
            _allowance[from][msg.sender] = _allowance[from][msg.sender].sub(value);
        }
        
        _transfer(from, to, value, new bytes(0));
        
        return true;
    }
    
    function transferWith(address from, address to, uint256 value, bytes calldata data) external override returns (bool) {
        if (_allowance[from][msg.sender] != uint(-1)) {
            _allowance[from][msg.sender] = _allowance[from][msg.sender].sub(value);
        }
        
        _transfer(from, to, value, data);
        
        return true;
    }
    
    // VIEW 
    
    function name() external view override returns (string memory) {
        return _name;
    }
    
    function symbol() external view override returns (string memory) {
        return _symbol;
    }
    
    function decimals() external view override returns (uint8) {
        return _decimals;
    }
    
    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }
    
    function balanceOf(address owner) external view override returns (uint256) {
        return _balanceOf[owner] >= 0 ? uint256(_balanceOf[owner]) : 0;
    }
    
    function debtOf(address owner) external view override returns (uint256) {
        return _debtOf(owner);
    }
    
    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowance[owner][spender];
    }
    
    function timeswapFactory() external view override returns (address) {
        return TIMESWAP_FACTORY;
    }
    
    
    // HELPER

    function _debtOf(address owner) private view returns (uint256) {
        return _balanceOf[owner] <= 0 ? uint256(_balanceOf[owner].negate()) : 0;
    }

    function _transfer(address from, address to, uint256 value, bytes memory data) private {
        require(to != address(0), "Timeswap Token: Zero Address");
        
        // avoid overflow between uint256 and in256
        int256 value0;
        int256 value1;
        if (value >= 2**255) {
            value0 = 2**255 - 1;
            value1 = int256(value - (2**255 - 1));
        }
        else {
            value0 = int256(value);
            value1 = 0;
        }
        
        int256 newBalanceFrom = _balanceOf[from].sub(value0).sub(value1); 
        int256 newBalanceTo = _balanceOf[to].add(value0).add(value1); 
        uint256 newSupply = _totalSupply;
        
        if (_balanceOf[from] >= 0 && newBalanceFrom < 0) {
            uint256 _supply = uint256(newBalanceFrom.negate());
            newSupply = newSupply.add(_supply);
            emit Transfer(address(0), from, _supply);
        } else if (_balanceOf[from] < 0) {
            uint256 _supply = uint256(_balanceOf[from].sub(newBalanceFrom));
            newSupply = newSupply.add(_supply);
            emit Transfer(address(0), from, _supply);
        }
        
        if (_balanceOf[to] < 0 && newBalanceTo >= 0) {
            uint256 _supply = uint256(_balanceOf[to].negate());
            newSupply = newSupply.sub(_supply);
            emit Transfer(to, address(0), _supply);
        } else if (newBalanceTo < 0) {
            uint256 _supply = uint256(newBalanceTo.sub(_balanceOf[to]));
            newSupply = newSupply.sub(_supply);
            emit Transfer(to, address(0), _supply);
        }
        
        _balanceOf[from] = newBalanceFrom; // optimistically transfer tokens
        _balanceOf[to] = newBalanceTo; // optimistically accept tokens
        _totalSupply = newSupply; // optimistically update supply
        
        if (data.length > 0) ITimeFlashCallee(to).timeFlashCall(msg.sender, value, data); // flash feature
        
        // check if the minimum collateral ratio is met
        /*
        if (_debtOf(from) > 0) {
            address timeswapCollateral = ITimeswapFactory(TIMESWAP_FACTORY).timeswapCollateral();
            require(ITimeswapCollateral(timeswapCollateral).checkCollateral(from, _debtOf(from)), "Timeswap Token: Not Enough Collateral");
        }
        */
        
        // add fee for flash feature

        emit Transfer(from, to, value);
    }
    
}
