import { utils } from 'ethers'
import MerkleTree from 'merkletreejs'
import invariant from 'tiny-invariant'

import { validate, prepareLeaves, ParsedStrategyRow } from './utils'

export class StrategyTree extends MerkleTree {
  private csv: ParsedStrategyRow

  constructor(data: string) {
    const csv = validate(data)

    invariant(
      csv.length > 0,
      'StrategyTree: Provided csv string did not produce a valid StrategyTree value'
    )
    prepareLeaves(csv)
    const leaves = csv.map((row) => row.leaf)
    super(leaves, utils.keccak256, { sort: true })

    this.csv = csv
  }

  get getCSV(): ParsedStrategyRow {
    return this.csv
  }
}
