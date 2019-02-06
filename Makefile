build:
	docker build -t quay.io/fishi/dns-sandbox:latest .

run: build
	docker run -p 4444:53/udp --name dns-sandbox -it quay.io/fishi/dns-sandbox:latest
