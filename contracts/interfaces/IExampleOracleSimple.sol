pragma solidity 0.7.6;


interface IExampleOracleSimple {

    function consult(address token, uint amountIn) external view returns (uint amountOut);
    function update() external;

}
