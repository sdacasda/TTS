#!/bin/bash
# Configuration check script

echo "================================"
echo "Azure Speech Portal Config Check"
echo "================================"
echo ""

# Check if .env file exists
if [ ! -f ".env" ]; then
    echo "❌ Error: .env file not found"
    exit 1
fi

echo "✓ .env file exists"
echo ""

# Read and display configuration (mask the key)
echo "Configuration:"
echo "-------------"

if grep -q "SPEECH_KEY=" .env; then
    key=$(grep "SPEECH_KEY=" .env | cut -d'=' -f2)
    if [ -n "$key" ]; then
        echo "✓ SPEECH_KEY: ${key:0:8}... (${#key} characters)"
    else
        echo "❌ SPEECH_KEY is empty"
    fi
else
    echo "❌ SPEECH_KEY not found in .env"
fi

if grep -q "SPEECH_REGION=" .env; then
    region=$(grep "SPEECH_REGION=" .env | cut -d'=' -f2)
    if [ -n "$region" ]; then
        echo "✓ SPEECH_REGION: $region"
    else
        echo "❌ SPEECH_REGION is empty"
    fi
else
    echo "❌ SPEECH_REGION not found in .env"
fi

echo ""
echo "Container Status:"
echo "----------------"
docker compose ps

echo ""
echo "Recent Logs:"
echo "-----------"
docker compose logs --tail=20 speech-portal

echo ""
echo "================================"
echo "To rebuild and restart:"
echo "  docker compose down"
echo "  docker compose up -d --build"
echo "================================"
