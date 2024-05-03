#!/usr/bin/env bash

set -e
# Unofficial bash strict mode.
# See: http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -u
set -o pipefail

UNAME=$(uname -s) SED=
case $UNAME in
  Darwin )      SED="gsed";;
  Linux )       SED="sed";;
esac

sprocket() {
  if [ "$UNAME" == "Windows_NT" ]; then
    # Named pipes names on Windows must have the structure: "\\.\pipe\PipeName"
    # See https://docs.microsoft.com/en-us/windows/win32/ipc/pipe-names
    echo -n '\\.\pipe\'
    echo "$1" | sed 's|/|\\|g'
  else
    echo "$1"
  fi
}

UNAME=$(uname -s) DATE=
case $UNAME in
  Darwin )      DATE="gdate";;
  Linux )       DATE="date";;
  MINGW64_NT* ) UNAME="Windows_NT"
                DATE="date";;
esac

CARDANO_CLI="${CARDANO_CLI:-cardano-cli}"
NETWORK_MAGIC=42
SECURITY_PARAM=10
NUM_SPO_NODES=3
INIT_SUPPLY=12000000
START_TIME="$(${DATE} -d "now + 5 seconds" +%s)"
ROOT=example
mkdir -p "${ROOT}"

cat > "${ROOT}/byron.genesis.spec.json" <<EOF
{
  "heavyDelThd":     "300000000000",
  "maxBlockSize":    "2000000",
  "maxTxSize":       "4096",
  "maxHeaderSize":   "2000000",
  "maxProposalSize": "700",
  "mpcThd": "20000000000000",
  "scriptVersion": 0,
  "slotDuration": "1000",
  "softforkRule": {
    "initThd": "900000000000000",
    "minThd": "600000000000000",
    "thdDecrement": "50000000000000"
  },
  "txFeePolicy": {
    "multiplier": "43946000000",
    "summand": "155381000000000"
  },
  "unlockStakeEpoch": "18446744073709551615",
  "updateImplicit": "10000",
  "updateProposalThd": "100000000000000",
  "updateVoteThd": "1000000000000"
}
EOF

$CARDANO_CLI byron genesis genesis \
  --protocol-magic ${NETWORK_MAGIC} \
  --start-time "${START_TIME}" \
  --k ${SECURITY_PARAM} \
  --n-poor-addresses 0 \
  --n-delegate-addresses ${NUM_SPO_NODES} \
  --total-balance ${INIT_SUPPLY} \
  --delegate-share 1 \
  --avvm-entry-count 0 \
  --avvm-entry-balance 0 \
  --protocol-parameters-file "${ROOT}/byron.genesis.spec.json" \
  --genesis-output-dir "${ROOT}/byron-gen-command"

cp scripts/babbage/alonzo-babbage-test-genesis.json "${ROOT}/genesis.alonzo.spec.json"
cp scripts/babbage/conway-babbage-test-genesis.json "${ROOT}/genesis.conway.spec.json"

cp configuration/defaults/byron-mainnet/configuration.yaml "${ROOT}/"
$SED -i "${ROOT}/configuration.yaml" \
     -e 's/Protocol: RealPBFT/Protocol: Cardano/' \
     -e '/Protocol/ aPBftSignatureThreshold: 0.6' \
     -e 's|GenesisFile: genesis.json|ByronGenesisFile: genesis/byron/genesis.json|' \
     -e '/ByronGenesisFile/ aShelleyGenesisFile: genesis/shelley/genesis.json' \
     -e '/ByronGenesisFile/ aAlonzoGenesisFile: genesis/shelley/genesis.alonzo.json' \
     -e '/ByronGenesisFile/ aConwayGenesisFile: genesis/shelley/genesis.conway.json' \
     -e 's/RequiresNoMagic/RequiresMagic/' \
     -e 's/LastKnownBlockVersion-Major: 0/LastKnownBlockVersion-Major: 8/' \
     -e 's/LastKnownBlockVersion-Minor: 2/LastKnownBlockVersion-Minor: 0/'

  echo "TestShelleyHardForkAtEpoch: 0" >> "${ROOT}/configuration.yaml"
  echo "TestAllegraHardForkAtEpoch: 0" >> "${ROOT}/configuration.yaml"
  echo "TestMaryHardForkAtEpoch: 0" >> "${ROOT}/configuration.yaml"
  echo "TestAlonzoHardForkAtEpoch: 0" >> "${ROOT}/configuration.yaml"
  echo "TestBabbageHardForkAtEpoch: 0" >> "${ROOT}/configuration.yaml"
  echo "TestConwayHardForkAtEpoch: 0" >> "${ROOT}/configuration.yaml"
  echo "ExperimentalProtocolsEnabled: True" >> "${ROOT}/configuration.yaml"
  echo "ExperimentalHardForksEnabled: True" >> "${ROOT}/configuration.yaml"

# Because in Babbage the overlay schedule and decentralization parameter
# are deprecated, we must use the "create-staked" cli command to create
# SPOs in the ShelleyGenesis
$CARDANO_CLI genesis create-staked --genesis-dir "${ROOT}" \
  --testnet-magic "${NETWORK_MAGIC}" \
  --gen-pools 3 \
  --supply            2000000000000 \
  --supply-delegated   240000000002 \
  --gen-stake-delegs 3 \
  --gen-utxo-keys 3

SPO_NODES="node-spo1 node-spo2 node-spo3"

# create the node directories
for NODE in ${SPO_NODES}; do

  mkdir "${ROOT}/${NODE}"

done

# Here we move all of the keys etc generated by create-staked
# for the nodes to use

# Move all genesis related files
mkdir -p "${ROOT}/genesis/byron"
mkdir -p "${ROOT}/genesis/shelley"

mv "${ROOT}/byron-gen-command/genesis.json" "${ROOT}/genesis/byron/genesis-wrong.json"
mv "${ROOT}/genesis.alonzo.json" "${ROOT}/genesis/shelley/genesis.alonzo.json"
mv "${ROOT}/genesis.conway.json" "${ROOT}/genesis/shelley/genesis.conway.json"
mv "${ROOT}/genesis.json" "${ROOT}/genesis/shelley/genesis.json"

jq --raw-output '.protocolConsts.protocolMagic = 42' "${ROOT}/genesis/byron/genesis-wrong.json" > "${ROOT}/genesis/byron/genesis.json"

rm "${ROOT}/genesis/byron/genesis-wrong.json"

cp "${ROOT}/genesis/shelley/genesis.json" "${ROOT}/genesis/shelley/copy-genesis.json"

jq -M '. + {slotLength:0.1, securityParam:10, activeSlotsCoeff:0.1, securityParam:10, epochLength:500, maxLovelaceSupply:10000000000000, updateQuorum:2}' "${ROOT}/genesis/shelley/copy-genesis.json" > "${ROOT}/genesis/shelley/copy2-genesis.json"
jq --raw-output '.protocolParams.protocolVersion.major = 9 | .protocolParams.minFeeA = 44 | .protocolParams.minFeeB = 155381 | .protocolParams.minUTxOValue = 1000000 | .protocolParams.decentralisationParam = 0.7 | .protocolParams.rho = 0.1 | .protocolParams.tau = 0.1' "${ROOT}/genesis/shelley/copy2-genesis.json" > "${ROOT}/genesis/shelley/genesis.json"

rm "${ROOT}/genesis/shelley/copy2-genesis.json"
rm "${ROOT}/genesis/shelley/copy-genesis.json"

mv "${ROOT}/pools/vrf1.skey" "${ROOT}/node-spo1/vrf.skey"
mv "${ROOT}/pools/vrf2.skey" "${ROOT}/node-spo2/vrf.skey"
mv "${ROOT}/pools/vrf3.skey" "${ROOT}/node-spo3/vrf.skey"

mv "${ROOT}/pools/opcert1.cert" "${ROOT}/node-spo1/opcert.cert"
mv "${ROOT}/pools/opcert2.cert" "${ROOT}/node-spo2/opcert.cert"
mv "${ROOT}/pools/opcert3.cert" "${ROOT}/node-spo3/opcert.cert"

mv "${ROOT}/pools/kes1.skey" "${ROOT}/node-spo1/kes.skey"
mv "${ROOT}/pools/kes2.skey" "${ROOT}/node-spo2/kes.skey"
mv "${ROOT}/pools/kes3.skey" "${ROOT}/node-spo3/kes.skey"

#Byron related

mv "${ROOT}/byron-gen-command/delegate-keys.000.key" "${ROOT}/node-spo1/byron-delegate.key"
mv "${ROOT}/byron-gen-command/delegate-keys.001.key" "${ROOT}/node-spo2/byron-delegate.key"
mv "${ROOT}/byron-gen-command/delegate-keys.002.key" "${ROOT}/node-spo3/byron-delegate.key"

mv "${ROOT}/byron-gen-command/delegation-cert.000.json" "${ROOT}/node-spo1/byron-delegation.cert"
mv "${ROOT}/byron-gen-command/delegation-cert.001.json" "${ROOT}/node-spo2/byron-delegation.cert"
mv "${ROOT}/byron-gen-command/delegation-cert.002.json" "${ROOT}/node-spo3/byron-delegation.cert"



echo 3001 > "${ROOT}/node-spo1/port"
echo 3002 > "${ROOT}/node-spo2/port"
echo 3003 > "${ROOT}/node-spo3/port"

# Make topology files
# Make topology files
#TODO generalise this over the N BFT nodes and pool nodes
cat > "${ROOT}/node-spo1/topology.json" <<EOF
{
   "Producers": [
     {
       "addr": "127.0.0.1",
       "port": 3002,
       "valency": 1
     }
   , {
       "addr": "127.0.0.1",
       "port": 3003,
       "valency": 1
     }
   ]
 }
EOF

cat > "${ROOT}/node-spo2/topology.json" <<EOF
{
   "Producers": [
     {
       "addr": "127.0.0.1",
       "port": 3001,
       "valency": 1
     }
   , {
       "addr": "127.0.0.1",
       "port": 3003,
       "valency": 1
     }
   ]
 }
EOF

cat > "${ROOT}/node-spo3/topology.json" <<EOF
{
   "Producers": [
     {
       "addr": "127.0.0.1",
       "port": 3001,
       "valency": 1
     }
   , {
       "addr": "127.0.0.1",
       "port": 3002,
       "valency": 1
     }
   ]
 }
EOF


for NODE in ${SPO_NODES}; do
  RUN_FILE="${ROOT}/${NODE}.sh"
  cat << EOF > "${RUN_FILE}"
#!/usr/bin/env bash

CARDANO_NODE="\${CARDANO_NODE:-cardano-node}"

\$CARDANO_NODE run \\
  --config                          '${ROOT}/configuration.yaml' \\
  --topology                        '${ROOT}/${NODE}/topology.json' \\
  --database-path                   '${ROOT}/${NODE}/db' \\
  --socket-path                     '$(sprocket "${ROOT}/${NODE}/node.sock")' \\
  --shelley-kes-key                 '${ROOT}/${NODE}/kes.skey' \\
  --shelley-vrf-key                 '${ROOT}/${NODE}/vrf.skey' \\
  --byron-delegation-certificate    '${ROOT}/${NODE}/byron-delegation.cert' \\
  --byron-signing-key               '${ROOT}/${NODE}/byron-delegate.key' \\
  --shelley-operational-certificate '${ROOT}/${NODE}/opcert.cert' \\
  --port                            $(cat "${ROOT}/${NODE}/port") \\
  | tee -a '${ROOT}/${NODE}/node.log'
EOF

  chmod a+x "${RUN_FILE}"

  echo "${RUN_FILE}"
done

mkdir -p "${ROOT}/run"

echo "#!/usr/bin/env bash" > "${ROOT}/run/all.sh"
echo "" >> "${ROOT}/run/all.sh"

for NODE in ${SPO_NODES}; do
  echo "$ROOT/${NODE}.sh &" >> "${ROOT}/run/all.sh"
done
echo "" >> "${ROOT}/run/all.sh"
echo "wait" >> "${ROOT}/run/all.sh"

chmod a+x "${ROOT}/run/all.sh"

echo "CARDANO_NODE_SOCKET_PATH=${ROOT}/node-spo1/node.sock "

(cd "$ROOT"; ln -s node-spo1/node.sock main.sock)
