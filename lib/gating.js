'use strict';

// The iptables commands that unlock ONE client after a successful login.
//
// Kept in a single place so the tests can pin the exact contract, from both
// sides (the Node test and the real-iptables test on the Pi):
//
//   1. firewall: drop the block, then allow the traffic. The gating chain ends
//      with a DROP, so the per-client ACCEPT must be inserted above it.
//   2. DNS: insert a RETURN at the TOP of the DNS chain. That chain ends with
//      a REDIRECT to the portal's dnsmasq, so putting RETURN first is what
//      stops hijacking this client: from now on it resolves for real and goes
//      out on "Rete 1". Without this rule the phone can never really browse.
//
// Order matters: it is the same sequence the portal runs on login.
function grantRules(clientIp, chain, dnsChain) {
  return [
    ['-D', chain, '-s', clientIp, '-j', 'DROP'],
    ['-I', chain, '-s', clientIp, '-j', 'ACCEPT'],
    ['-t', 'nat', '-D', dnsChain, '-s', clientIp, '-j', 'RETURN'],
    ['-t', 'nat', '-I', dnsChain, '-s', clientIp, '-j', 'RETURN']
  ];
}

module.exports = { grantRules };
