#!/usr/bin/env bash
# Compiled by Sylvester Kuisis
# Maintained by Thabang Maahlo
# Post-installation script for the Platforma Dialer on CentOS 7

APP_NAME="dialer"
APP_HOME=$(${APP_NAME} config:get APP_HOME)

APP_USER=$(${APP_NAME} config:get APP_USER)
APP_GROUP=$(${APP_NAME} config:get APP_GROUP)
REC_DIR=/var/punchblock/record
REC_STORAGE_DIR=/var/teleforge/recordings/dialer

# Copy startup script to correct directory and set to executable
cp ${APP_HOME}/packaging/centos7/startup/${APP_NAME}.service /lib/systemd/system/${APP_NAME}.service

# Set dialer config variables
${APP_NAME} config:set AHN_CALL_MANAGER_AGENT_TRUNK=SIP/dialer/
${APP_NAME} config:set AHN_CALL_MANAGER_OUTBOUND_TRUNK=SIP/billing/
${APP_NAME} config:set AHN_ENIGMA_HTTP_API_BASE=http://localhost:8000
${APP_NAME} config:set AHN_PLATFORM_LOGGING_LEVEL=info
${APP_NAME} config:set AHN_PUNCHBLOCK_PASSWORD=L1ttl3p1gl3t
${APP_NAME} config:set AHN_PUNCHBLOCK_USERNAME=lloydtest
${APP_NAME} config:set JAVA_MEM=-Xmx1g
${APP_NAME} config:set RECORDING_MANAGER_STORAGE_DIR=${REC_STORAGE_DIR}

# Create directory for Punchblock
mkdir -p ${REC_DIR}
chown ${APP_USER}:${APP_GROUP} ${REC_DIR} # Will cause permission issues if asterisk runs as asterisk: DIAL-433

# Create directory for Recordings
mkdir -p ${REC_STORAGE_DIR}
chown ${APP_USER}:${APP_GROUP} ${REC_STORAGE_DIR}

exit 0
