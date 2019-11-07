pragma solidity ^0.5.8;

contract MerkleTree {

    /*
    @notice Explanation of the Merkle Tree in this contract:
    This is an append-only merkle tree; populated from left to right.
    We do not store all of the merkle tree's nodes. We only store the right-most 'frontier' of nodes required to calculate the new root when the next new leaf value is added.

                      TREE (not stored)                       FRONTIER (stored)

                                 0                                     ?
                          /             \
                   1                             2                     ?
               /       \                     /       \
           3             4               5               6             ?
         /   \         /   \           /   \           /    \
       7       8      9      10      11      12      13      14        ?
     /  \    /  \   /  \    /  \    /  \    /  \    /  \    /  \
    15  16  17 18  19  20  21  22  23  24  25  26  27  28  29  30      ?

    level  row  width  start#     end#
      4     0   2^0=1   w=0     2^1-1=0
      3     1   2^1=2   w=1     2^2-1=2
      2     2   2^2=4   w=3     2^3-1=6
      1     3   2^3=8   w=7     2^4-1=14
      0     4   2^4=16  w=15    2^5-1=30

    height = 4
    w = width = 2 ** height = 2^4 = 16
    #nodes = (2 ** (height + 1)) - 1 = 2^5-1 = 31

    */

    event newLeaf(uint leafIndex, bytes32 leafValue, bytes32 root); // This event is what the merkle-tree microservice's filter will listen for. We assume that some importing contract will be the one to actually emit this event, because it will be the importing contract which manages permissions for inserting a leaf into this tree.
    event newLeaves(uint minLeafIndex, bytes32[] leafValues, bytes32 root);

    bytes32 zero = 0x0000000000000000000000000000000000000000000000000000000000000000;
    uint public treeHeight;
    uint public treeWidth; // 2 ^ treeHeight
    bytes32[33] frontier; // fixed-size arrays are cheaper to use
    // bytes32[] public frontier; // the right-most 'frontier' of nodes required to calculate the new root when the next new leaf value is added.
    uint256 public leafCount; // the number of leaves currently in the tree

    constructor(uint _treeHeight) public {
        treeHeight = _treeHeight;
        treeWidth = 2 ** _treeHeight;
        // frontier = new bytes32[](treeHeight + 1);
    }

    function getFrontierSlot(uint leafIndex) internal pure returns (uint slot) {
        slot = 0;
        if ( leafIndex % 2 == 1 ) {
            uint exp1 = 1;
            uint pow1 = 2;
            uint pow2 = pow1 << 1;
            while (slot == 0) {
                if ( (leafIndex + 1 - pow1) % pow2 == 0 ) {
                    slot = exp1;
                } else {
                    pow1 = pow2;
                    pow2 = pow2 << 1;
                    exp1++;
                }
            }
        }
    }



    function insertLeaf(bytes32 leafValue) public returns (bytes32) {

        uint slot = getFrontierSlot(leafCount);
        uint nodeIndex = leafCount + treeWidth - 2;
        bytes32 nodeValue = leafValue; // nodeValue is the hash, which iteratively gets overridden to the top of the tree until it becomes the root.

        bytes32[2] memory inputs; // the left and right inputs to the hash function.
        bytes32[1] memory output;
        bool success;


        for (uint level = 0; level < treeHeight; level++) {

            if (level == slot) frontier[slot] = nodeValue;

            if (nodeIndex % 2 == 0) {
                // even nodeIndex
                inputs[0] = frontier[level];
                inputs[1] = nodeValue;
                // compute the hash of the inputs:
                // note: we don't extract this hashing into a separate function because that would cost more gas.
                assembly {
                    success := call(not(0), 2, 0, inputs, 0x40, output, 0x20)
                    // Use "invalid" to make gas estimation work
                    switch success case 0 { invalid() }
                }
                nodeValue = output[0]; // the parentValue, but will become the nodeValue of the next level
                nodeIndex = (nodeIndex - 1) / 2; // move one row up the tree
            } else {
                // odd nodeIndex
                inputs[0] = nodeValue;
                inputs[1] = zero;
                // compute the hash of the inputs:
                assembly {
                    success := call(not(0), 2, 0, inputs, 0x40, output, 0x20)
                    switch success case 0 { invalid() }
                }
                nodeValue = output[0]; // the parentValue, but will become the nodeValue of the next level
                nodeIndex = nodeIndex / 2; // move one row up the tree
            }
        }

        // refund gas by deleting a redundant frontier slot:
        // if (slot > 0) frontier[slot - 1] = 0; // THIS ACTUALLY COSTS MORE IN THE LONG RUN!

        emit newLeaf(leafCount, leafValue, nodeValue); // this event is what the merkle-tree microservice's filter will listen for.

        leafCount++; // the incrememnting of leafCount costs us 20k for the first leaf, and 5k thereafter

        return nodeValue; //the root of the tree
    }




    function insertLeaves(bytes32[] memory leafValues) public returns (bytes32) {
        uint numberOfLeaves = leafValues.length;
        // check that space exists in the tree:
        if ( numberOfLeaves > treeWidth - leafCount ) {
            numberOfLeaves = treeWidth - leafCount; // we'll ignore any extra leaves
        }

        uint slot;
        uint nodeIndex;
        bytes32 nodeValue;

        bytes32[2] memory inputs; // the left and right inputs to the hash function.
        bytes32[1] memory output; // the output of the hash
        bool success;

        // consider each new leaf in turn, from left to right:
        for (uint leafIndex = leafCount; leafIndex < numberOfLeaves; leafIndex++) {
            nodeValue = leafValues[leafIndex - leafCount];

            slot = getFrontierSlot(leafIndex); // determine at which level we will next need to store a nodeValue

            if (slot == 0) {
                frontier[slot] = nodeValue; // store in frontier
                continue;
            }

            nodeIndex = leafIndex + treeWidth - 2; // convert the leafIndex to a nodeIndex

            // hash up to the level whose nodeValue we'll store in the frontier slot:
            for (uint level = 1; level <= slot; level++) {
                if (nodeIndex % 2 == 0) {
                    // even nodeIndex
                    inputs[0] = frontier[level - 1];
                    inputs[1] = nodeValue;
                    // compute the hash of the inputs:
                    // note: we don't extract this hashing into a separate function because that would cost more gas.
                    assembly {
                        success := call(not(0), 2, 0, inputs, 0x40, output, 0x20)
                        // Use "invalid" to make gas estimation work
                        switch success case 0 { invalid() }
                    }
                    nodeValue = output[0]; // the parentValue, but will become the nodeValue of the next level
                    nodeIndex = (nodeIndex - 1) / 2; // move one row up the tree
                } else {
                    // odd nodeIndex
                    inputs[0] = nodeValue;
                    inputs[1] = zero;
                    // compute the hash of the inputs:
                    assembly {
                        success := call(not(0), 2, 0, inputs, 0x40, output, 0x20)
                        switch success case 0 { invalid() }
                    }
                    nodeValue = output[0]; // the parentValue, but will become the nodeValue of the next level
                    nodeIndex = nodeIndex / 2; // the parentIndex, but will become the nodeIndex of the next level
                }
            }
            frontier[slot] = nodeValue; // store in frontier
        }

        // So far we've added all leaves, and hashed up to a particular level of the tree. We now need to continue hashing from that level until the root:
        for (uint level = slot + 1; level <= treeHeight; level++) {

            if (nodeIndex % 2 == 0) {
                // even nodeIndex
                inputs[0] = frontier[level - 1];
                inputs[1] = nodeValue;
                // compute the hash of the inputs:
                assembly {
                    success := call(not(0), 2, 0, inputs, 0x40, output, 0x20)
                    switch success case 0 { invalid() }
                }
                nodeValue = output[0]; // the parentValue, but will become the nodeValue of the next level
                nodeIndex = (nodeIndex - 1) / 2;  // the parentIndex, but will become the nodeIndex of the next level
            } else {
                // odd nodeIndex
                inputs[0] = nodeValue;
                inputs[1] = zero;
                // compute the hash of the inputs:
                assembly {
                    success := call(not(0), 2, 0, inputs, 0x40, output, 0x20)
                    switch success case 0 { invalid() }
                }
                nodeValue = output[0]; // the parentValue, but will become the nodeValue of the next level
                nodeIndex = nodeIndex / 2;  // the parentIndex, but will become the nodeIndex of the next level
            }
        }
        // nodeValue is now the root of the tree

        emit newLeaves(leafCount, leafValues, nodeValue); // this event is what the merkle-tree microservice's filter will listen for.

        leafCount += numberOfLeaves; // the incrememnting of leafCount costs us 20k for the first leaf, and 5k thereafter

        return nodeValue; //the root of the tree
    }

    // for Remix testing only:
    function bytes32Encoder(uint valueToConvertToLeafValue) public returns (bytes32) {
        bytes32 leafValue = bytes32(valueToConvertToLeafValue);
        return insertLeaf(leafValue);
    }

    // [1234,2345,3456,4567]
    // [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25]
    function bytes32ArrayEncoder(uint[25] memory valuesToConvertToLeafValues) public returns (bytes32) {
        bytes32[] memory leafValues = new bytes32[](25);
        for (uint i = 0; i < valuesToConvertToLeafValues.length; i++) {
            leafValues[i] = bytes32(valuesToConvertToLeafValues[i]);
        }
        return insertLeaves(leafValues);
    }
}