const { createProxyMiddleware } = require("http-proxy-middleware");

const APEX_API_ORIGIN = "https://api.gocloudlaunch.com";
const REGIONAL_PROXY_PATH = /^\/api\/regions\/([a-z0-9-]+)(\/.*)?$/;

module.exports = function setupProxy(app) {
    app.use(createProxyMiddleware("/api", {
        changeOrigin: true,
        router: (request) => {
            const match = request.url.match(REGIONAL_PROXY_PATH);
            return match
                ? `https://${match[1]}.gocloudlaunch.com`
                : APEX_API_ORIGIN;
        },
        pathRewrite: (path) => path.replace(REGIONAL_PROXY_PATH, "/api$2"),
    }));
};
