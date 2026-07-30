location        = "eastus"
env             = "dev"
vpn_gateway_sku = "Basic" # "VpnGw1" if you later want BGP or P2S

# Admin access
admin_username = "azureuser"
ssh_public_key = "ssh-ed25519 AAAA... your-public-key"

# S2S pre-shared key — DO NOT commit a real value; prefer TF_VAR_vpn_shared_key.
vpn_shared_key = "change-me-to-a-strong-random-string"