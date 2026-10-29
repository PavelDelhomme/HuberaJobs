const authRoutes = require('../../src/routes/auth.routes');
const authController = require('../../src/controllers/auth.controller');

function findRoute(router, method, path) {
  return router.stack.find((layer) => {
    if (!layer.route) return false;
    return layer.route.path === path && layer.route.methods[method] === true;
  });
}

describe('POST /api/v1/auth/login/hubera-sso', () => {
  test('la route est branchée sur loginHuberaSso', () => {
    const layer = findRoute(authRoutes, 'post', '/login/hubera-sso');
    expect(layer).toBeTruthy();
    const handlers = layer.route.stack.map((entry) => entry.handle);
    expect(handlers).toContain(authController.loginHuberaSso);
  });
});
