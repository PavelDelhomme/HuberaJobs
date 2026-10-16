const { betaChannelBlocked, isBetaAccount } = require('../src/lib/betaChannel');

const allow = 'lab@example.com, beta@example.org';

describe('verrou bêta Jobs', () => {
  it('reconnaît la liste, pas un compte absent', () => {
    expect(isBetaAccount('Lab@Example.com', allow)).toBe(true);
    expect(isBetaAccount('autre@example.com', allow)).toBe(false);
    expect(isBetaAccount('', allow)).toBe(false);
    expect(isBetaAccount(null, '')).toBe(false);
  });

  it('404 seulement sur channel=beta pour un non-bêta', () => {
    expect(betaChannelBlocked('beta', 'autre@example.com', allow)).toBe(true);
    expect(betaChannelBlocked('beta', '', allow)).toBe(true);
    expect(betaChannelBlocked('beta', 'lab@example.com', allow)).toBe(false);
    expect(betaChannelBlocked('production', 'autre@example.com', allow)).toBe(false);
    expect(betaChannelBlocked('dev', null, allow)).toBe(false);
    expect(betaChannelBlocked('preprod', 'autre@example.com', allow)).toBe(false);
  });
});
