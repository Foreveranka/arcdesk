# Arcdesk deploy tool (local only)

Browser-based deployer: connect your wallet, deploy both escrow legs, verify the wiring.
Your private key never leaves the wallet — this page only requests signatures.

    cd ~/arcdesk/tools && python3 -m http.server 8123
    open http://localhost:8123/deploy.html

NEVER publish this directory. It is an admin tool and is deliberately kept out of web/,
which is the folder deployed to Vercel.

After any contract change, regenerate the bytecode:

    cd ~/arcdesk/contracts && forge build
    python3 -c "import json; b=json.load(open('out/ArcdeskEscrow.sol/ArcdeskEscrow.json'))['bytecode']['object']; open('../tools/bytecode.js','w').write('window.ARCDESK_BYTECODE = \"%s\";\n' % b)"
