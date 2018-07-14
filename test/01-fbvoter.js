'use strict';

import expectThrow from '../node_modules/openzeppelin-solidity/test/helpers/expectThrow';
import expectEvent from '../node_modules/openzeppelin-solidity/test/helpers/expectEvent';

const BigNumber = web3.BigNumber;
const chai =require('chai');
chai.use(require('chai-bignumber')(BigNumber));
chai.use(require('chai-as-promised')); // Order is important
chai.should();

const FbVoter = artifacts.require("FbVoter");

//function daysInFutureTimestamp(days) {
//	const now = new Date();
//	const futureDate = new Date(+now + 86400 * days);
//	return Math.trunc(futureDate.getTime()/1000);
// }

async function assertTokenDiff(voterContract, voter, oldValue, wantDiff) {

	let nowBalance = await voterContract.balanceOf(voter);
	console.log("[DEBUG] User has " + oldValue + " and now have " + nowBalance);
	nowBalance.sub(oldValue).should.be.bignumber.equal(wantDiff);
}

contract('FbVoter - constructor and setters', function(accounts) {
	const acc = {owner: accounts[0], alice: accounts[1], bob: accounts[2], carol: accounts[3], eva: accounts[4]};


	let fbVoter;
	it('deploys contract and spreads tokens', async function() {
		fbVoter = await FbVoter.new({from: acc.owner});


		/*
		let totalSupply = await fbVoter.INITIAL_SUPPLY();

		await assertTokenDiff(fbVoter, acc.owner, 0, totalSupply);
		fbVoter.transfer(acc.alice, 20, {from:acc.owner});
		await assertTokenDiff(fbVoter, acc.alice, 0, +20);

		await fbVoter.transfer(acc.bob, 15, {from:acc.owner});
		await fbVoter.transfer(acc.carol, 10, {from:acc.owner});
		await fbVoter.transfer(acc.eva, 5, {from:acc.owner});
		// now owner:50, alice: 20, bob: 15, carol: 10, eva: 5
		*/
	});

	it('alice place a challenge and fucked out', async function() {
		//let VOTE_ALICE = "alice_wants_this_variant";

		//await fbVoter.initChallenge(VOTE_ALICE, 10, {from: acc.alice}); 
		//await expectThrow(fbVoter.initChallenge("alice", 10, {from: acc.alice})); 
		//await assertTokenDiff(fbVoter, acc.alice, 20, -10);

		// hide secret answer against 
		// to vote for string bob uses any string, containing voting variant
		// await fbVoter.commitChallengeVote("alice_wants_this", 5, bobHash{from: acc.bob}); 


	});


});
