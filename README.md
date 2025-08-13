# collabfun
trustless collaborative token launch

a fully trustless smart contract on a Chain for two untrusting parties to collaboratively launch a BEP-20 memecoin. 

Requirement:

Both parties deposit half of required amount to deploy and add liquidity to the contract.
Theres a form on the website asking for Name, Symbol, Decimals, Supply, Description, Image, advanced options (check below)
Contract creates a token
A multisig wallet is created
Tokens are sent to the multisig 
Contract adds liquidity to DEX, sending LP tokens to the multisig.
All actions are automated, requiring both parties’ signatures via multisig.
No manual transfers or trust windows.
User-friendly: Non-technical users can interact via Safe’s UI.
Include refund mechanism if one party doesn’t deposit.

Advanced options:
Modify Creator Information: Change the information of the creator in the metadata, by default it is our projects name
Custom Address Generator: Customize the beginning and/or the end of the token contract address and make the difference
Multi-Wallet Supply Distribution: Distribute the supply of the token to different wallets within the creation. 
Add DEXTools Socials + Banner: Add  token information on DEXTools profile with a discounted price and much faster. 
Revoke Freeze Authority: No one will be able to freeze holders' token accounts anymore
Revoke Mint Authority: No one will be able to create more tokens anymore
Revoke Update Authority: No one will be able to modify token metadata anymore
