pragma solidity ^0.6.5;

interface IERC1155TokenReceiver {
    function onERC1155Received(address _operator, address _from, uint256 _id, uint256 _value, bytes calldata _data) external returns (bytes4);
    function onERC1155BatchReceived(address _operator, address _from, uint256[] calldata _ids, uint256[] calldata _values, bytes calldata _data) external returns (bytes4);
}

interface ITimeFlashCallee {
    // UPDATE 
    
    function timeFlashCall(address _operator, uint256 _id, uint256 _value, bytes calldata _data) external;
    function timeFlashCallBatch(address _operator, uint256[] memory _ids, uint256[] memory _values, bytes calldata _data) external;
}

library SafeMathUint256 {
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x, "SafeMathUint256: Add Overflow");
    }
    
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x, "SafeMathUint256: Sub Overflow");
    }
}

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

library Address {
    function isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly { size := extcodesize(account) }
        return size > 0;
    }
}

contract TimeswapTokenERC1155 {
    using SafeMathUint256 for uint256;
    using SafeMathInt256 for int256;
    using Address for address;
    
    // CONSTANT 
    
    address immutable TIMESWAP_FACTORY;
    
    bytes4 constant internal ERC1155_ACCEPTED = 0xf23a6e61; // bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"))
    bytes4 constant internal ERC1155_BATCH_ACCEPTED = 0xbc197c81; // bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"))

    // MODEL
    
    // owner => maturity date => balance
    // when balance > 0 means owner can swap equivalent balance of underlying tokens after maturity date
    // when balance < 0 means owner will lose ownership of collaterals after maturity date minus one hour
    mapping(address => mapping(uint256 => int256)) _balance;
    
    // owner => operator => approved
    mapping(address => mapping(address => bool)) _approval;
    
    // INIT
    
    constructor() public {
        TIMESWAP_FACTORY = msg.sender;
    }
    
    // EVENT 
    
    event TransferSingle(address indexed _operator, address indexed _from, address indexed _to, uint256 _id, uint256 _value);
    event TransferBatch(address indexed _operator, address indexed _from, address indexed _to, uint256[] _ids, uint256[] _values);
    event ApprovalForAll(address indexed _owner, address indexed _operator, bool _approved);
    event URI(string _value, uint256 indexed _id);
    
    // UPDATE
    
    // _id represents the maturity date
    // can transfer even if _value is greater than the balance
    // automatically reverts if minimum collateral ratio is not met
    function safeTransferFrom(address _from, address _to, uint256 _id, uint256 _value, bytes calldata _data) external {
        require(_to != address(0), "Timeswap Token: Cannot Send to Zero Address");
        require(_from == msg.sender || _approval[_from][msg.sender], "Timeswap Token: Not Approve to Send Tokens");
        
        // avoid overflows between uint256 and int256
        int256 _value0;
        int256 _value1;
        if (_value > 2**255 - 1) {
            _value0 = 2**255 - 1;
            _value1 = int256(_value - (2**255 - 1));
        } else {
            _value0 = int256(_value);
            _value1 = 0;
        }
        
        // optimistically transfer tokens
        _balance[_from][_id] = _balance[_from][_id].sub(_value0).sub(_value1);
        _balance[_to][_id] = _balance[_to][_id].add(_value0).add(_value1);
        
        // flash feature
        if (_data.length > 0) ITimeFlashCallee(_to).timeFlashCall(msg.sender, _id, _value, _data);
        
        // check collateral
        require(_balance[_from][_id] >= 0 || _checkCollateral(_id, _from), "Timeswap Token: Not Enough Collateral");
        
        // add flash fees
        
        // check if receiver is a smart contract
        if (_to.isContract()) {
            _doSafeTransferAcceptanceCheck(msg.sender, _from, _to, _id, _value, _data);
        }
        
        emit TransferSingle(msg.sender, _from, _to, _id, _value);
    }
    
    // _ids represent maturity dates respectively
    // can transfer even if _values are greater than balances respectively
    // automatically reverts is minimum collateral ratio is not met
    function safeBatchTransferFrom(address _from, address _to, uint256[] calldata _ids, uint256[] calldata _values, bytes calldata _data) external {
        require(_to != address(0), "Timeswap Token: Cannot Send to Zero Address");
        require(_ids.length == _values.length, "Timeswap Token: Array Length Must Match");
        require(_from == msg.sender || _approval[_from][msg.sender], "Timeswap Token: Not Approve to Send Tokens");
        
        for (uint256 _i = 0; _i < _ids.length; ++_i) {
            // avoid stacks too deep error
            uint256 _id = _ids[_i];
            uint256 _value = _values[_i];
            address __from = _from;
            address __to = _to;
            
            // avoid overflows between uint256 and int256
            int256 _value0;
            int256 _value1;
            if (_value > 2**255 - 1) {
                _value0 = 2**255 - 1;
                _value1 = int256(_value - (2**255 - 1));
            } else {
                _value0 = int256(_value);
                _value1 = 0;
            }
            
            // optimistically transfer tokens
            _balance[__from][_id] = _balance[__from][_id].sub(_value0).sub(_value1);
            _balance[__to][_id] = _balance[__to][_id].add(_value0).add(_value1);
        }
        
        // flash feature
        if (_data.length > 0) ITimeFlashCallee(_to).timeFlashCallBatch(msg.sender, _ids, _values, _data); 
        
        for (uint256 _i = 0; _i < _ids.length; ++_i) {
            uint256 _id = _ids[_i];
            
            // check collateral
            require(_balance[_from][_id] >= 0 || _checkCollateral(_id, _from), "Timeswap Token: Not Enough Collateral");
        }
        
        // add flash fees
        
        // check if receiver is a smart contract
        if (_to.isContract()) {
            _doSafeBatchTransferAcceptanceCheck(msg.sender, _from, _to, _ids, _values, _data);
        }
        
        emit TransferBatch(msg.sender, _from, _to, _ids, _values);
    }
    
    function setApprovalForAll(address _operator, bool _approved) external {
        _approval[msg.sender][_operator] = _approved;
        
        emit ApprovalForAll(msg.sender, _operator, _approved);
    }
    
    // VIEW 
    
    function balanceOf(address _owner, uint256 _id) external view returns (uint256) {
        return _balance[_owner][_id] > 0 ? uint256(_balance[_owner][_id]) : 0;
    }
    
    function debtOf(address _owner, uint256 _id) external view returns (uint256) {
        return _balance[_owner][_id] < 0 ? uint256(_balance[_owner][_id].negate()) : 0;
    }
    
    function balanceOfBatch(address[] calldata _owners, uint256[] calldata _ids) external view returns (uint256[] memory) {
        require(_owners.length == _ids.length, "Timeswap Token: Array Length Must Match");
        
        uint256[] memory _balances = new uint256[](_owners.length);
        
        for (uint256 _i = 0; _i < _owners.length; _i++) {
            address _owner = _owners[_i];
            uint256 _id = _ids[_i];
            
            _balances[_i] = _balance[_owner][_id] > 0 ? uint256(_balance[_owner][_id]) : 0;
        }
        
        return _balances;
    }
    
    function debtOfBatch(address[] calldata _owners, uint256[] calldata _ids) external view returns (uint256[] memory) {
        require(_owners.length == _ids.length, "Timeswap Token: Array Length Must Match");
        
        uint256[] memory _debts = new uint256[](_owners.length);
        
        for (uint256 _i = 0; _i < _owners.length; _i++) {
            address _owner = _owners[_i];
            uint256 _id = _ids[_i];
            
            _debts[_i] = _balance[_owner][_id] < 0 ? uint256(_balance[_owner][_id].negate()) : 0;
        }
        
        return _debts;
    }
    
    function isApprovedForAll(address _owner, address _operator) external view returns (bool) {
        return _approval[_owner][_operator];
    }
    
    // HELPER
    
    // Fix it soon
    function _checkCollateral(uint256 _id, address _from) private view returns (bool) {
        return true;
    }
    
    function _doSafeTransferAcceptanceCheck(address _operator, address _from, address _to, uint256 _id, uint256 _value, bytes memory _data) private {
        require(IERC1155TokenReceiver(_to).onERC1155Received(_operator, _from, _id, _value, _data) == ERC1155_ACCEPTED, "Timeswap Token: Invalid Return");
    }
    
    function _doSafeBatchTransferAcceptanceCheck(address _operator, address _from, address _to, uint256[] memory _ids, uint256[] memory _values, bytes memory _data) private {
        require(IERC1155TokenReceiver(_to).onERC1155BatchReceived(_operator, _from, _ids, _values, _data) == ERC1155_BATCH_ACCEPTED, "Timeswap Token: Invalid Return");
    }
    
}
