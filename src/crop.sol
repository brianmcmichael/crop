pragma solidity 0.6.12;

import "dss-interfaces/dss/VatAbstract.sol";

interface ERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address dst, uint256 amount) external returns (bool);
    function transferFrom(address src, address dst, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function decimals() external returns (uint8);
}

// receives tokens and shares them among holders
contract CropJoin {

    VatAbstract public immutable vat;    // cdp engine
    bytes32     public immutable ilk;    // collateral type
    ERC20       public immutable gem;    // collateral token
    uint256     public immutable dec;    // gem decimals
    ERC20       public immutable bonus;  // rewards token

    uint256     public share;  // crops per gem    [ray]
    uint256     public total;  // total gems       [wad]
    uint256     public stock;  // crop balance     [wad]

    mapping (address => uint256) public crops; // crops per user  [wad]
    mapping (address => uint256) public stake; // gems per user   [wad]

    // --- Events ---
    event Join(uint256 val);
    event Exit(uint256 val);
    event Flee();
    event Tack(address indexed src, address indexed dst, uint256 wad);

    constructor(address vat_, bytes32 ilk_, address gem_, address bonus_) public {
        vat = VatAbstract(vat_);
        ilk = ilk_;
        gem = ERC20(gem_);
        uint256 dec_ = ERC20(gem_).decimals();
        require(dec_ <= 18);
        dec = dec_;

        bonus = ERC20(bonus_);
    }

    function add(uint256 x, uint256 y) public pure returns (uint256 z) {
        require((z = x + y) >= x, "ds-math-add-overflow");
    }
    function sub(uint256 x, uint256 y) public pure returns (uint256 z) {
        require((z = x - y) <= x, "ds-math-sub-underflow");
    }
    function mul(uint256 x, uint256 y) public pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x, "ds-math-mul-overflow");
    }
    uint256 constant WAD  = 10 ** 18;
    function wmul(uint256 x, uint256 y) public pure returns (uint256 z) {
        z = mul(x, y) / WAD;
    }
    function wdiv(uint256 x, uint256 y) public pure returns (uint256 z) {
        z = mul(x, WAD) / y;
    }
    uint256 constant RAY  = 10 ** 27;
    function rmul(uint256 x, uint256 y) public pure returns (uint256 z) {
        z = mul(x, y) / RAY;
    }
    function rdiv(uint256 x, uint256 y) public pure returns (uint256 z) {
        z = mul(x, RAY) / y;
    }

    // Net Asset Valuation [wad]
    function nav() public virtual returns (uint256) {
        uint256 _nav = gem.balanceOf(address(this));
        return mul(_nav, 10 ** (18 - dec));
    }

    // Net Assets per Share [wad]
    function nps() public returns (uint256) {
        if (total == 0) return WAD;
        else return wdiv(nav(), total);
    }

    function crop() internal virtual returns (uint256) {
        return sub(bonus.balanceOf(address(this)), stock);
    }

    function join(uint256 val) public virtual {
        uint256 wad = wdiv(mul(val, 10 ** (18 - dec)), nps());
        require(int256(wad) >= 0);

        if (total > 0) share = add(share, rdiv(crop(), total));

        address usr = msg.sender;
        require(bonus.transfer(usr, sub(rmul(stake[usr], share), crops[usr])));
        stock = bonus.balanceOf(address(this));
        if (wad > 0) {
            require(gem.transferFrom(usr, address(this), val));
            vat.slip(ilk, usr, int256(wad));

            total = add(total, wad);
            stake[usr] = add(stake[usr], wad);
        }
        crops[usr] = rmul(stake[usr], share);

        emit Join(val);
    }

    function exit(uint256 val) public virtual {
        uint256 wad = wdiv(mul(val, 10 ** (18 - dec)), nps());
        require(int256(wad) >= 0);

        if (total > 0) share = add(share, rdiv(crop(), total));

        address usr = msg.sender;
        require(bonus.transfer(usr, sub(rmul(stake[usr], share), crops[usr])));
        stock = bonus.balanceOf(address(this));
        if (wad > 0) {
            require(gem.transfer(usr, val));
            vat.slip(ilk, usr, -int256(wad));

            total = sub(total, wad);
            stake[usr] = sub(stake[usr], wad);
        }
        crops[usr] = rmul(stake[usr], share);

        emit Exit(val);
    }

    function flee() public virtual {
        address usr = msg.sender;

        uint256 wad = vat.gem(ilk, usr);
        uint256 val = wmul(wmul(wad, nps()), 10 ** dec);

        require(gem.transfer(usr, val));
        vat.slip(ilk, usr, -int(wad));

        total = sub(total, wad);
        stake[usr] = sub(stake[usr], wad);
        crops[usr] = rmul(stake[usr], share);

        emit Flee();
    }

    function tack(address src, address dst, uint256 wad) public {
        stake[src] = sub(stake[src], wad);
        stake[dst] = add(stake[dst], wad);

        crops[src] = sub(crops[src], rmul(share, wad));
        crops[dst] = add(crops[dst], rmul(share, wad));

        (uint256 ink,) = vat.urns(ilk, src);
        require(stake[src] >= add(vat.gem(ilk, src), ink));
        (ink,) = vat.urns(ilk, dst);
        require(stake[dst] <= add(vat.gem(ilk, dst), ink));

        emit Tack(src, dst, wad);
    }

}
