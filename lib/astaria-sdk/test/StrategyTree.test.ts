import { join } from 'path'
import { readFile } from 'fs/promises'

import { StrategyTree } from '../src/strategy/StrategyTree'

describe('StrategyTree', () => {
  test('parses CSV into BinaryTree', async () => {
    const csv = await readFile(join(__dirname, '__mocks__/test.csv'), 'utf8')

    const strategyTree = new StrategyTree(csv)

    expect(
      '0x451fad0e5b357b99cdde7ebe462ef028dbd5506e1db82b5937c0ebee78dcd3f0'
    ).toEqual(strategyTree.getHexRoot())
  })
})
