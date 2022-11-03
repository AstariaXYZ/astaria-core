import { BigNumber } from '@ethersproject/bignumber'
import { Web3Provider, ExternalProvider } from '@ethersproject/providers'
import { AddressZero } from '@ethersproject/constants'
import ganache from 'ganache'
import { Wallet } from 'ethers'
import { join } from 'path'
import { readFile } from 'fs/promises'

import { StrategyTree } from '../src/strategy/StrategyTree'
import {
  signRootRemote,
  signRootLocal,
  getTypedData,
  encodeIPFSStrategyPayload,
} from '../src/strategy/utils'
import { Strategy } from '../src/types'

describe('util.signRoot using remote', () => {
  test('signs merkle tree root', async () => {
    const options = {
      wallet: {
        mnemonic: 'junk junk junk junk junk junk junk junk junk junk junk test',
      },
      logging: {
        quiet: true,
      },
    }

    const ganacheProvider: unknown = ganache.provider<'ethereum'>(options)
    const provider = new Web3Provider(ganacheProvider as ExternalProvider)

    const verifyingContract = AddressZero
    const strategy: Strategy = {
      version: 0,
      strategist: AddressZero,
      expiration: BigNumber.from(0),
      nonce: BigNumber.from(0),
      vault: AddressZero,
    }
    const root =
      '0x451fad0e5b357b99cdde7ebe462ef028dbd5506e1db82b5937c0ebee78dcd3f0'

    const sig = await signRootRemote(
      strategy,
      provider,
      root,
      verifyingContract,
      0
    )

    expect(sig.compact).toEqual(
      '0x00d6bdd90151dcf83b578a735be4a2d71a46ae08bde99e9aa23d1eaf4c24fc1619987e97f52e004a642ecbc9629f3069ac78133c441ef946f988a27c44726e77'
    )
  })
  test('signs merkle tree root using local', async () => {
    const wallet = Wallet.fromMnemonic(
      'junk junk junk junk junk junk junk junk junk junk junk test'
    )
    const verifyingContract = AddressZero
    const strategy: Strategy = {
      version: 0,
      strategist: AddressZero,
      expiration: BigNumber.from(0),
      nonce: BigNumber.from(0),
      vault: AddressZero,
    }
    const root =
      '0x451fad0e5b357b99cdde7ebe462ef028dbd5506e1db82b5937c0ebee78dcd3f0'

    const sig = await signRootLocal(
      strategy,
      wallet,
      root,
      verifyingContract,
      0
    )

    expect(sig.compact).toEqual(
      '0x00d6bdd90151dcf83b578a735be4a2d71a46ae08bde99e9aa23d1eaf4c24fc1619987e97f52e004a642ecbc9629f3069ac78133c441ef946f988a27c44726e77'
    )
  })
  test('encoding and decoding for IPFS', async () => {
    const csv = await readFile(join(__dirname, '__mocks__/test.csv'), 'utf8')
    const expected = await readFile(
      join(__dirname, '__mocks__/encode.json'),
      'utf8'
    )

    const strategyTree = new StrategyTree(csv)

    const root = strategyTree.getHexRoot()
    const wallet = Wallet.fromMnemonic(
      'junk junk junk junk junk junk junk junk junk junk junk test'
    )
    const verifyingContract = AddressZero
    const strategy: Strategy = {
      version: 0,
      strategist: AddressZero,
      expiration: BigNumber.from(0),
      nonce: BigNumber.from(0),
      vault: AddressZero,
    }
    const typedData = getTypedData(strategy, root, verifyingContract, 0)
    const signature = await signRootLocal(
      strategy,
      wallet,
      root,
      verifyingContract,
      0
    )
    const strategyPayload = encodeIPFSStrategyPayload(
      typedData,
      signature,
      strategyTree.getCSV
    )

    expect(strategyPayload).toEqual(expected)
  })
})
