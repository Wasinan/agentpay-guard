# AgentPay Guard demo UI — packaged as a static image.
# Build:  docker build -t agentpay-guard .
# Run:    docker run --rm -p 8080:80 agentpay-guard
# Then open http://localhost:8080 and connect a wallet on Aevum Testnet.
FROM nginx:alpine
COPY web/ /usr/share/nginx/html/
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
