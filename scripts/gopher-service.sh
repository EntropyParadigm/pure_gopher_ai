#!/bin/bash
# PureGopherAI service management script
# Usage: sudo ./scripts/gopher-service.sh [start|stop|restart|status|logs|load|unload]

PLIST="/Library/LaunchDaemons/com.puregopherai.server.plist"
LABEL="com.puregopherai.server"
LOG_FILE="/Users/gopher/.gopher/server.log"
ERROR_LOG="/Users/gopher/.gopher/server-error.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

case "$1" in
    start)
        echo "Starting PureGopherAI service..."
        if [ "$EUID" -ne 0 ]; then
            echo -e "${RED}Please run with sudo${NC}"
            exit 1
        fi
        launchctl start $LABEL
        sleep 2
        if launchctl list | grep -q $LABEL; then
            echo -e "${GREEN}Service started${NC}"
        else
            echo -e "${RED}Failed to start service${NC}"
            exit 1
        fi
        ;;

    stop)
        echo "Stopping PureGopherAI service..."
        if [ "$EUID" -ne 0 ]; then
            echo -e "${RED}Please run with sudo${NC}"
            exit 1
        fi
        launchctl stop $LABEL
        echo -e "${GREEN}Service stopped${NC}"
        ;;

    restart)
        echo "Restarting PureGopherAI service..."
        if [ "$EUID" -ne 0 ]; then
            echo -e "${RED}Please run with sudo${NC}"
            exit 1
        fi
        launchctl stop $LABEL
        sleep 2
        launchctl start $LABEL
        sleep 2
        echo -e "${GREEN}Service restarted${NC}"
        ;;

    status)
        echo "PureGopherAI Service Status"
        echo "==========================="

        # Check if plist exists
        if [ -f "$PLIST" ]; then
            echo -e "Plist: ${GREEN}Installed${NC}"
        else
            echo -e "Plist: ${RED}Not installed${NC}"
            exit 1
        fi

        # Check if loaded
        if launchctl list 2>/dev/null | grep -q $LABEL; then
            echo -e "Service: ${GREEN}Loaded${NC}"

            # Get PID
            PID=$(launchctl list | grep $LABEL | awk '{print $1}')
            if [ "$PID" != "-" ] && [ -n "$PID" ]; then
                echo -e "PID: ${GREEN}$PID${NC}"
                echo -e "Running: ${GREEN}Yes${NC}"
            else
                echo -e "Running: ${YELLOW}No (service loaded but not running)${NC}"
            fi
        else
            echo -e "Service: ${RED}Not loaded${NC}"
        fi

        # Test connection
        echo ""
        echo "Testing Gopher connection..."
        if echo "" | nc -w 2 localhost 70 &>/dev/null; then
            echo -e "Connection: ${GREEN}OK${NC}"
        else
            echo -e "Connection: ${RED}Failed${NC}"
        fi

        # Show recent log entries
        echo ""
        echo "Recent log entries:"
        if [ -f "$LOG_FILE" ]; then
            tail -5 "$LOG_FILE" 2>/dev/null || echo "(no logs yet)"
        else
            echo "(log file not found)"
        fi
        ;;

    logs)
        if [ -f "$LOG_FILE" ]; then
            echo "Showing logs (Ctrl+C to exit)..."
            tail -f "$LOG_FILE"
        else
            echo "Log file not found: $LOG_FILE"
            exit 1
        fi
        ;;

    errors)
        if [ -f "$ERROR_LOG" ]; then
            echo "Showing error logs (Ctrl+C to exit)..."
            tail -f "$ERROR_LOG"
        else
            echo "Error log file not found: $ERROR_LOG"
            exit 1
        fi
        ;;

    load)
        echo "Loading PureGopherAI service..."
        if [ "$EUID" -ne 0 ]; then
            echo -e "${RED}Please run with sudo${NC}"
            exit 1
        fi
        if [ ! -f "$PLIST" ]; then
            echo -e "${RED}Plist not found. Run setup-gopher-user.sh first.${NC}"
            exit 1
        fi
        launchctl load $PLIST
        echo -e "${GREEN}Service loaded (will start on boot)${NC}"
        ;;

    unload)
        echo "Unloading PureGopherAI service..."
        if [ "$EUID" -ne 0 ]; then
            echo -e "${RED}Please run with sudo${NC}"
            exit 1
        fi
        launchctl unload $PLIST
        echo -e "${GREEN}Service unloaded (won't start on boot)${NC}"
        ;;

    test)
        echo "Testing Gopher server..."
        echo ""
        echo "Sending root selector..."
        RESPONSE=$(echo "" | nc -w 5 localhost 70 2>/dev/null)
        if [ -n "$RESPONSE" ]; then
            echo -e "${GREEN}Server responding!${NC}"
            echo ""
            echo "First 10 lines of response:"
            echo "$RESPONSE" | head -10
        else
            echo -e "${RED}No response from server${NC}"
            exit 1
        fi
        ;;

    *)
        echo "PureGopherAI Service Manager"
        echo ""
        echo "Usage: $0 {start|stop|restart|status|logs|errors|load|unload|test}"
        echo ""
        echo "Commands:"
        echo "  start   - Start the service"
        echo "  stop    - Stop the service"
        echo "  restart - Stop and start the service"
        echo "  status  - Show service status and test connection"
        echo "  logs    - Follow the server log (Ctrl+C to exit)"
        echo "  errors  - Follow the error log (Ctrl+C to exit)"
        echo "  load    - Load service (enable auto-start on boot)"
        echo "  unload  - Unload service (disable auto-start)"
        echo "  test    - Test the Gopher server response"
        echo ""
        exit 1
        ;;
esac
