#!/bin/bash
# Fix HeyFoS DNS Record

ZONE_ID="72731de3f08d42d689f39c81a9e4f42c"
API_TOKEN="Ys_GrDi7QLD4kO6HoKnXlvXZ5OjhhhrrqJrEeN3j"
DOMAIN="heyfos.truyenthong.edu.vn"
TUNNEL_ID="ec599d7a-b844-4d00-8bcf-4a573d13d5bd"

echo "🔍 Finding existing DNS records for $DOMAIN..."

# Get existing records
RECORDS=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$DOMAIN" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json")

echo "$RECORDS" | jq '.result[] | {id, type, name, content}'

# Delete existing A/AAAA/CNAME records
echo ""
echo "🗑️  Deleting old DNS records..."

RECORD_IDS=$(echo "$RECORDS" | jq -r '.result[] | .id')

for RECORD_ID in $RECORD_IDS; do
  echo "Deleting record $RECORD_ID..."
  curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json" | jq '.success'
done

# Create CNAME record
echo ""
echo "✅ Creating CNAME record..."

curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  --data "{
    \"type\": \"CNAME\",
    \"name\": \"heyfos\",
    \"content\": \"$TUNNEL_ID.cfargotunnel.com\",
    \"proxied\": true,
    \"ttl\": 1
  }" | jq '.'

echo ""
echo "✅ DNS record updated successfully!"
echo "🌐 Please wait 1-2 minutes for DNS propagation"
