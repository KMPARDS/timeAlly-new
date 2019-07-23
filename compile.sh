node compile.js
cp build/Eraswap_0.json ../timeally-react/src/ethereum/compiledContracts/
cp build/NRTManager_0.json ../timeally-react/src/ethereum/compiledContracts/
cp build/TimeAlly_0.json ../timeally-react/src/ethereum/compiledContracts/
if [ $1 == 'deploy' ]
then
   node deploy.js $2
fi
