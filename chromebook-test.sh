#!/bin/bash
# Chromebook/Crostini test helper
# Crostini doesn't have KVM, so we use Docker only

echo "Checking Crostini compatibility..."

# Crostini has Docker but no KVM
if [ ! -w /dev/kvm ] 2>/dev/null; then
    echo "No KVM (expected on Chromebook) - using Docker mode only"
fi

# Check Docker is running
if ! docker info > /dev/null 2>&1; then
    echo "Starting Docker..."
    sudo service docker start
    sleep 2
fi

case "${1:-help}" in
    build)
        docker build -t galactica:test --target runtime .
        ;;
    shell)
        # Interactive shell inside Galactica environment
        docker run --rm -it --privileged \
            -v "$(pwd)/docker/services:/etc/airride/services:ro" \
            --hostname galactica \
            galactica:test /bin/bash
        ;;
    airride)
        # Run AirRide in foreground, can ctrl+c to stop
        docker run --rm -it --privileged \
            -v "$(pwd)/docker/services:/etc/airride/services:ro" \
            --hostname galactica \
            galactica:test /sbin/airride
        ;;
    ctl)
        # Send airridectl commands to running airride container
        # Usage: ./chromebook-test.sh ctl list
        #        ./chromebook-test.sh ctl start echo-test
        CONTAINER=$(docker ps -qf "name=airride-sock-test" | head -1)
        if [ -z "$CONTAINER" ]; then
            echo "Start airride first: docker run -d --privileged --name airride-sock-test -v \$(pwd)/docker/services:/etc/airride/services:ro galactica:test /sbin/airride"
            exit 1
        fi
        docker exec "$CONTAINER" /usr/bin/airridectl "$@"
        ;;
    dreamland)
        shift
        docker run --rm -it galactica:test /usr/bin/dreamland "$@"
        ;;
    test)
        bash docker-test.sh
        ;;
    *)
        echo "Usage: $0 {build|shell|airride|ctl|dreamland|test}"
        echo ""
        echo "  build       - Build Docker image"
        echo "  shell       - Interactive bash in Galactica container"
        echo "  airride     - Run AirRide init in foreground"
        echo "  ctl [cmd]   - Send command to running AirRide"
        echo "  dreamland   - Run dreamland commands"
        echo "  test        - Run test suite"
        ;;
esac
