//SPDX-License-Identifier: UNLICENSED

/* See contracts/COMPILERS.md */
pragma solidity 0.8.17;

/* Importing relevant contracts from OpenZeppelin */
import "./@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./@openzeppelin/contracts/access/Ownable.sol";
import "./@openzeppelin/contracts/interfaces/IERC20.sol";

/**
 * HDG-20 Fund Standard
 * @title Returns-bearing ERC20-like token to be used instead of traditional fund infrastructure.
 *
 *
 * FUND client balances are dynamic, representing the holder's share in the total amount
 * of assets controlled by the fund. Account shares aren't normalized, so the
 * contract also stores the sum of all shares to calculate each account's token balance
 * which equals to:
 *
 *  balance(account) = shares[account] * _getTotalPooledUSDC() / _getTotalShares()
 *
 * Therefore:
 *
 *   balanceOf(user1) -> 2 tokens which corresponds 2 USDC
 *   balanceOf(user2) -> 8 tokens which corresponds 8 USDC
 *
 * We can adjust the total amount of assets held by simply asjusting the totalPooledUSDC value as a parameter. We set a function to do so.
 * In practice, a manager should do so as much as possible to keep clients informed of their position.
 *
 * Further improvements can be made by implementing a parent 'factory' contract, that
 *
 * Since balances of all token holders change when the amount of total pooled USDC
 * changes, this token cannot fully implement ERC20 standard: it only emits `Transfer`
 * events upon explicit transfer between holders. In contrast, when total amount of
 * pooled USDC increases, no `Transfer` events are generated: doing so would require
 * emitting an event for each token holder and thus running an unbounded loop.
 *
 * The token inherits from  `Ownable` modifier for methods. This is useful as it restricts a role soley for the manager.
 *
 * We still use IERC20 to be able to interact with decentralised exchanges, like that of Uniswap.
 */
contract FUND is IERC20, Ownable {
    // Safemath used to prevent underflows or overflows.
    using SafeMath for uint256;

    /**
     * @dev FUND balances are dynamic and are calculated based on the accounts' shares
     * and the total amount of USDC controlled by the protocol. Account shares aren't
     * normalized, so the contract also stores the sum of all shares to calculate
     * each account's token balance which equals to:
     *
     *   shares[account] * _getTotalPooledUSDC() / _getTotalShares()
     */
    mapping(address => uint256) private shares;

    /**
     * @dev Allowances are nominated in tokens, not token shares.
     */
    mapping(address => mapping(address => uint256)) private allowances;

    /**
     * @dev Allowances are nominated in tokens, not token shares.
     */
    mapping(address => uint256) private requests;

    /**
     * @dev Storage position used for holding the total amount of shares in existence.
     */
    uint256 public TOTAL_SHARES_POSITION = 0;

    /**
     * @dev Storage position used for holding the total amount of shares in existence.
     */
    uint256 public TOTAL_POOLED_USDC = 0;

    /**
     * @dev Address of USDC, used for connecting to the interface. Future implementations of this contract will have this variable defined in a constructor,
     * but for the sake of this coursework it is hard-coded.
     */
    address public USDC_ADDRESS = 0x326C977E6efc84E512bB9C30f76E30c160eD06FB;

    /**
     * @notice An executed shares transfer from `sender` to `recipient`.
     *
     * @dev emitted in pair with an ERC20-defined `Transfer` event.
     */
    event TransferShares(
        address indexed from,
        address indexed to,
        uint256 sharesValue
    );

    /**
     * @notice An executed `burnShares` request
     *
     * @dev Reports simultaneously burnt shares amount
     * and corresponding USDC amount.
     * The USDC amount is calculated twice: before and after the burning incurred rebase.
     *
     * @param account holder of the burnt shares
     * @param preRebaseTokenAmount amount of USDC the burnt shares corresponded to before the burn
     * @param postRebaseTokenAmount amount of USDC the burnt shares corresponded to after the burn
     * @param sharesAmount amount of burnt shares
     */
    event SharesBurnt(
        address indexed account,
        uint256 preRebaseTokenAmount,
        uint256 postRebaseTokenAmount,
        uint256 sharesAmount
    );

    /**
     * @notice An increase/decrease to the 'TOTAL_POOLED_USDC' value.
     *
     * @dev Reports quantity of TOTAL_POOLED_USDC present before and after the change.
     *
     * @param preRebaseAmount amount of USDC the burnt shares corresponded to before the burn
     * @param postRebaseAmount amount of USDC the burnt shares corresponded to after the burn
     */
    event SetTotalPooledUSDC(
        uint256 preRebaseAmount, 
        uint256 postRebaseAmount
    );

    /**
     * @notice An increase/decrease to the 'TOTAL_POOLED_USDC' value.
     *
     * @dev Reports quantity of TOTAL_POOLED_USDC present before and after the change.
     *
     */
    event Invest(
        address account, 
        uint256 amountUSDCIn
    );

    /**
     * @notice An increase/decrease to the 'TOTAL_POOLED_USDC' value.
     *
     * @dev Reports quantity of TOTAL_POOLED_USDC present before and after the change.

     */
    event Withdraw(
        address account, 
        uint256 amountUSDCOut
    );

    /**
     * @return the name of the token.
     */
    function name() public pure returns (string memory) {
        return "Hedge Fund UCL";
    }

    /**
     * @return the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public pure returns (string memory) {
        return "UCL";
    }

    /**
     * @return the number of decimals for getting user representation of a token amount.
     */
    function decimals() public pure returns (uint8) {
        return 18;
    }

    /**
     * @return the amount of tokens in existence.
     *
     * @dev Always equals to `_getTotalPooledUSDC()` since token amount
     * is pegged to the total amount of USDC controlled by the hedge fund.
     */
    function totalSupply() public view returns (uint256) {
        return TOTAL_POOLED_USDC;
    }

    /**
     * @return the entire amount of USDC controlled by the protocol.
     *
     * @dev The sum of all USDC balances in the protocol, equals to the total supply of USDC.
     */
    function getTotalPooledUSDC() public view returns (uint256) {
        return TOTAL_POOLED_USDC;
    }

    /**
     * @return the amount of tokens owned by the `_account`.
     *
     * @dev Balances are dynamic and equal the `_account`'s share in the amount of the
     * total USDC controlled by the protocol. See `sharesOf`.
     */
    function balanceOf(address _account) public view returns (uint256) {
        return getPooledUSDCByShares(_sharesOf(_account));
    }

    /**
     * @return the amount of tokens requests by the `_account`.
     *
     * @dev Balances are dynamic and equal the `_account`'s share in the amount of the
     * total USDC controlled by the protocol. See `sharesOf`.
     */
    function requestOf(address _account) public view returns (uint256) {
        return requests[_account];
    }

    /**
     * @return the amount of USDC owned by the `_account`.
     * Note this uses the balance of another contract.
     */
    function USDCBalance(address _account) public view returns (uint256) {
        return IERC20(USDC_ADDRESS).balanceOf(_account);
    }

    /**
     * @return the amount of USDC owned by the `_account`.
     *
     * This value is derived from from the ERC-20 token USDC, which has its own individual balance function and mapping.
     */
    function withdrawableUSDC() public view returns (uint256) {
        return IERC20(USDC_ADDRESS).balanceOf(address(this));
    }

    /**
     * @notice Moves `_amount` tokens from the caller's account to the `_recipient` account.
     *
     * @return a boolean value indicating whether the operation succeeded.
     * Emits a `Transfer` event.
     * Emits a `TransferShares` event.
     *
     * Requirements:
     *
     * - `_recipient` cannot be the zero address.
     * - the caller must have a balance of at least `_amount`.
     * - the contract must not be paused.
     *
     * @dev The `_amount` argument is the amount of tokens, not shares.
     */
    function transfer(address _recipient, uint256 _amount)
        public
        returns (bool)
    {
        _transfer(msg.sender, _recipient, _amount);
        return true;
    }

    /**
     * @return the remaining number of tokens that `_spender` is allowed to spend
     * on behalf of `_owner` through `transferFrom`. This is zero by default.
     *
     * @dev This value changes when `approve` or `transferFrom` is called.
     */
    function allowance(address _owner, address _spender)
        public
        view
        returns (uint256)
    {
        return allowances[_owner][_spender];
    }

    /**
     * @notice Sets `_amount` as the allowance of `_spender` over the caller's tokens.
     *
     * @return a boolean value indicating whether the operation succeeded.
     * Emits an `Approval` event.
     *
     * Requirements:
     *
     * - `_spender` cannot be the zero address.
     * - the contract must not be paused.
     *
     * @dev The `_amount` argument is the amount of tokens, not shares.
     */
    function approve(address _spender, uint256 _amount) public returns (bool) {
        _approve(msg.sender, _spender, _amount);
        return true;
    }

    /**
     * @notice Moves `_amount` tokens from `_sender` to `_recipient` using the
     * allowance mechanism. `_amount` is then deducted from the caller's
     * allowance.
     *
     * @return a boolean value indicating whether the operation succeeded.
     *
     * Emits a `Transfer` event.
     * Emits a `TransferShares` event.
     * Emits an `Approval` event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `_sender` and `_recipient` cannot be the zero addresses.
     * - `_sender` must have a balance of at least `_amount`.
     * - the caller must have allowance for `_sender`'s tokens of at least `_amount`.
     * - the contract must not be paused.
     *
     * @dev The `_amount` argument is the amount of tokens, not shares.
     */
    function transferFrom(
        address _sender,
        address _recipient,
        uint256 _amount
    ) public returns (bool) {
        uint256 currentAllowance = allowances[_sender][msg.sender];
        require(
            currentAllowance >= _amount,
            "TRANSFER_AMOUNT_EXCEEDS_ALLOWANCE"
        );

        _transfer(_sender, _recipient, _amount);
        _approve(_sender, msg.sender, currentAllowance.sub(_amount));
        return true;
    }

    /**
     * @notice Atomically increases the allowance granted to `_spender` by the caller by `_addedValue`.
     *
     * This is an alternative to `approve` that can be used as a mitigation for
     * problems described in:
     * https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/IERC20.sol#L42
     * Emits an `Approval` event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `_spender` cannot be the the zero address.
     * - the contract must not be paused.
     */
    function increaseAllowance(address _spender, uint256 _addedValue)
        public
        returns (bool)
    {
        _approve(
            msg.sender,
            _spender,
            allowances[msg.sender][_spender].add(_addedValue)
        );
        return true;
    }

    /**
     * @notice Atomically decreases the allowance granted to `_spender` by the caller by `_subtractedValue`.
     *
     * This is an alternative to `approve` that can be used as a mitigation for
     * problems described in:
     * https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/IERC20.sol#L42
     * Emits an `Approval` event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `_spender` cannot be the zero address.
     * - `_spender` must have allowance for the caller of at least `_subtractedValue`.
     * - the contract must not be paused.
     */
    function decreaseAllowance(address _spender, uint256 _subtractedValue)
        public
        returns (bool)
    {
        uint256 currentAllowance = allowances[msg.sender][_spender];
        require(
            currentAllowance >= _subtractedValue,
            "DECREASED_ALLOWANCE_BELOW_ZERO"
        );
        _approve(msg.sender, _spender, currentAllowance.sub(_subtractedValue));
        return true;
    }

    /**
     * @return the total amount of shares in existence.
     *
     * @dev The sum of all accounts' shares can be an arbitrary number, therefore
     * it is necessary to store it in order to calculate each account's relative share.
     */
    function getTotalShares() public view returns (uint256) {
        return _getTotalShares();
    }

    /**
     * @return the amount of shares owned by `_account`.
     */
    function sharesOf(address _account) public view returns (uint256) {
        return _sharesOf(_account);
    }

    /**
     * @return the amount of shares that corresponds to `_USDCAmount` protocol-controlled USDC.
     */
    function getSharesByPooledUSDC(uint256 _USDCAmount)
        public
        view
        returns (uint256)
    {
        uint256 totalPooledUSDC = TOTAL_POOLED_USDC;
        if (totalPooledUSDC == 0) {
            return 0;
        } else {
            return _USDCAmount.mul(_getTotalShares()).div(totalPooledUSDC);
        }
    }

    /**
     * @return the amount of USDC that corresponds to `_sharesAmount` token shares.
     */
    function getPooledUSDCByShares(uint256 _sharesAmount)
        public
        view
        returns (uint256)
    {
        uint256 totalShares = _getTotalShares();
        if (totalShares == 0) {
            return 0;
        } else {
            return _sharesAmount.mul(TOTAL_POOLED_USDC).div(totalShares);
        }
    }

    /**
     * @notice Moves `_sharesAmount` token shares from the caller's account to the `_recipient` account.
     *
     * @return amount of transferred tokens.
     * Emits a `TransferShares` event.
     * Emits a `Transfer` event.
     *
     * Requirements:
     *
     * - `_recipient` cannot be the zero address.
     * - the caller must have at least `_sharesAmount` shares.
     * - the contract must not be paused.
     *
     * @dev The `_sharesAmount` argument is the amount of shares, not tokens.
     */
    function transferShares(address _recipient, uint256 _sharesAmount)
        public
        returns (uint256)
    {
        _transferShares(msg.sender, _recipient, _sharesAmount);
        emit TransferShares(msg.sender, _recipient, _sharesAmount);
        uint256 tokensAmount = getPooledUSDCByShares(_sharesAmount);
        emit Transfer(msg.sender, _recipient, tokensAmount);
        return tokensAmount;
    }

    /**
     * @notice Moves `_amount` tokens from `_sender` to `_recipient`.
     * Emits a `Transfer` event.
     * Emits a `TransferShares` event.
     */
    function _transfer(
        address _sender,
        address _recipient,
        uint256 _amount
    ) internal {
        uint256 _sharesToTransfer = getSharesByPooledUSDC(_amount);
        _transferShares(_sender, _recipient, _sharesToTransfer);
        emit Transfer(_sender, _recipient, _amount);
        emit TransferShares(_sender, _recipient, _sharesToTransfer);
    }

    /**
     * @notice Sets `_amount` as the allowance of `_spender` over the `_owner` s tokens.
     *
     * Emits an `Approval` event.
     *
     * Requirements:
     *
     * - `_owner` cannot be the zero address.
     * - `_spender` cannot be the zero address.
     * - the contract must not be paused.
     */
    function _approve(
        address _owner,
        address _spender,
        uint256 _amount
    ) internal {
        require(_owner != address(0), "APPROVE_FROM_ZERO_ADDRESS");
        require(_spender != address(0), "APPROVE_TO_ZERO_ADDRESS");

        allowances[_owner][_spender] = _amount;
        emit Approval(_owner, _spender, _amount);
    }

    /**
     * @return the total amount of shares in existence.
     */
    function _getTotalShares() internal view returns (uint256) {
        return TOTAL_SHARES_POSITION;
    }

    /**
     * @return the amount of shares owned by `_account`.
     */
    function _sharesOf(address _account) internal view returns (uint256) {
        return shares[_account];
    }

    /**
     * @notice Moves `_sharesAmount` shares from `_sender` to `_recipient`.
     *
     * Requirements:
     *
     * - `_sender` cannot be the zero address.
     * - `_recipient` cannot be the zero address.
     * - `_sender` must hold at least `_sharesAmount` shares.
     * - the contract must not be paused.
     */
    function _transferShares(
        address _sender,
        address _recipient,
        uint256 _sharesAmount
    ) internal {
        require(_sender != address(0), "TRANSFER_FROM_THE_ZERO_ADDRESS");
        require(_recipient != address(0), "TRANSFER_TO_THE_ZERO_ADDRESS");

        uint256 currentSenderShares = shares[_sender];
        require(
            _sharesAmount <= currentSenderShares,
            "TRANSFER_AMOUNT_EXCEEDS_BALANCE"
        );

        shares[_sender] = currentSenderShares.sub(_sharesAmount);
        shares[_recipient] = shares[_recipient].add(_sharesAmount);
    }

    /**
     * @dev Processes user deposits, mints liquid tokens and increase the total amount of pooledUSDC by that exact amount.
     * Manager is then able to withdraw the pooled USDC and invest it, before increasing/decreasing.
     * @return amount of USDC shares generated
     */
    function invest(uint256 _amount) external returns (uint256) {
        require(USDCBalance(msg.sender) >= _amount, "INSUFFICIENT_FUNDS");
        require(_amount != 0, "ZERO_DEPOSIT");
        require(
            IERC20(USDC_ADDRESS).allowance(msg.sender, address(this)) >=
                _amount,
            "INSUFFICIENT_ALLOWANCE"
        );

        //There must be an approval before this, executed on the USDC contract.
        IERC20(USDC_ADDRESS).transferFrom(msg.sender, address(this), _amount);

        uint256 sharesAmount = getSharesByPooledUSDC(_amount);
        if (sharesAmount == 0) {
            // totalControlledUSDC is 0: either the first-ever deposit or complete slashing
            sharesAmount = _amount;
        }

        _setTotalPooledUSDC(TOTAL_POOLED_USDC + _amount);
        _mintShares(msg.sender, sharesAmount);
        emit Invest(msg.sender, _amount);
        return sharesAmount;
    }

    /**
     * @notice Processes managers withdrawal of the USDC owned in the contract.
     */
    function withdrawUSDCForInvestment(uint256 _amount) external onlyOwner {
        require(_amount != 0, "ZERO_WITHDRAWAL");
        require(_amount <= USDCBalance(address(this)), "INSUFFICIENT_USDC");
        IERC20(USDC_ADDRESS).transfer(msg.sender, _amount);
    }

    /**
     * @notice Allows user to request their assets back from the investment, the manager is then able to reimburse by that amount. 
     *
     */
    function request(uint256 _amount)
    external
    {
        require(_amount != 0, "ZERO_WITHDRAWAL_REQUEST");
        require(_amount <= balanceOf(msg.sender), "INSUFFICIENT_FUNDS");
        require(requests[msg.sender] == 0, "REQUEST_ALREADY_PENDING");
        requests[msg.sender] = _amount;
    }

    /**
     * @notice Allows manager to pay the requested funds in the the clients account. 
     *
     */
    function payRequest(address _account) external onlyOwner { 

        //Getting amount of the request...
        uint256 _amount = requestOf(_account);
        require(
            IERC20(USDC_ADDRESS).allowance(msg.sender, address(this)) >=
                _amount,
            "INSUFFICIENT_ALLOWANCE"
        );
        require(
            IERC20(USDC_ADDRESS).balanceOf(address(this)) >= _amount,
            "INSUFFICIENT_FUNDS"
        );

        //Burning the shares of the witdrawing account.
        uint256 sharesAmount = getSharesByPooledUSDC(_amount);
        _burnShares(msg.sender, sharesAmount);

        //Transferring USDC to the requesting account. 
        IERC20(USDC_ADDRESS).transferFrom(msg.sender, _account, _amount);

        //Setting request to zero.
        requests[_account] = 0;

        //Submitting a withdrawal event
        emit Withdraw(msg.sender, _amount);
    }

    /**
     * @notice Creates `_sharesAmount` shares and assigns them to `_recipient`, increasing the total amount of shares.
     * @dev This doesn't increase the token total supply.
     *
     * Requirements:
     *
     * - `_recipient` cannot be the zero address.
     * - the contract must not be paused.
     */
    function _mintShares(address _recipient, uint256 _sharesAmount)
        internal
        returns (uint256 newTotalShares)
    {
        require(_recipient != address(0), "MINT_TO_THE_ZERO_ADDRESS");

        newTotalShares = _getTotalShares().add(_sharesAmount);
        TOTAL_SHARES_POSITION = newTotalShares;
        shares[_recipient] = shares[_recipient].add(_sharesAmount);

        // Notice: we're not emitting a Transfer event from the zero address here since shares mint
        // works by taking the amount of tokens corresponding to the minted shares from all other
        // token holders, proportionally to their share. The total supply of the token doesn't change
        // as the result. This is equivalent to performing a send from each other token holder's
        // address to `address`, but we cannot reflect this as it would require sending an unbounded
        // number of events.
    }

    /**
     * @notice Destroys `_sharesAmount` shares from `_account`'s holdings, decreasing the total amount of shares.
     * @dev This doesn't decrease the token total supply.
     *
     * Requirements:
     *
     * - `_account` cannot be the zero address.
     * - `_account` must hold at least `_sharesAmount` shares.
     * - the contract must not be paused.
     */
    function _burnShares(address _account, uint256 _sharesAmount)
        internal
        returns (uint256 newTotalShares)
    {
        require(_account != address(0), "BURN_FROM_THE_ZERO_ADDRESS");

        uint256 accountShares = shares[_account];
        require(_sharesAmount <= accountShares, "BURN_AMOUNT_EXCEEDS_BALANCE");
        uint256 preRebaseTokenAmount = getPooledUSDCByShares(_sharesAmount);
        newTotalShares = _getTotalShares().sub(_sharesAmount);
        TOTAL_SHARES_POSITION = newTotalShares;
        shares[_account] = accountShares.sub(_sharesAmount);
        uint256 postRebaseTokenAmount = getPooledUSDCByShares(_sharesAmount);
        emit SharesBurnt(
            _account,
            preRebaseTokenAmount,
            postRebaseTokenAmount,
            _sharesAmount
        );

        // Notice: we're not emitting a Transfer event to the zero address here since shares burn
        // works by redistributing the amount of tokens corresponding to the burned shares between
        // all other token holders. The total supply of the token doesn't change as the result.
        // This is equivalent to performing a send from `address` to each other token holder address,
        // but we cannot reflect this as it would require sending an unbounded number of events.
        // We're emitting `SharesBurnt` event to provide an explicit rebase log record nonetheless.
    }

    /**
     * @notice Allows the owner to redifine the balances of all clients within the system, by changing the TOTAL_POOLED_USDC.
     * This is not entirely the same giving returns, and doesnt deposit USDC into the contract. It just changes how much each investor is 'owed'.
     * Think of this as adjusting the 'I owe you' quantities which are the balances.
     *
     * - `_newPooledUSDCAmound` cannot be the zero address.
     */
    function _setTotalPooledUSDC(uint256 _newPooledUSDCAmound) internal {
        uint256 preRebaseAmount = TOTAL_POOLED_USDC;
        TOTAL_POOLED_USDC = _newPooledUSDCAmound;
        uint256 postRebaseAmount = _newPooledUSDCAmound;
        emit SetTotalPooledUSDC(preRebaseAmount, postRebaseAmount);
    }

    /**
     * @notice Allows the owner to redifine the balances of all clients within the system, by changing the TOTAL_POOLED_USDC.
     * This is not entirely the same giving returns, and doesnt deposit USDC into the contract. It just changes how much each investor is 'owed'.
     * Think of this as adjusting the 'I owe you' quantities which are the balances.
     *
     * - `_newPooledUSDCAmound` cannot be the zero address.
     */
    function setTotalPooledUSDCOwner(uint256 _newPooledUSDCAmound)
        external
        onlyOwner
    {
        _setTotalPooledUSDC(_newPooledUSDCAmound);
    }

}
