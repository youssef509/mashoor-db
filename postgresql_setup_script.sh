#!/bin/bash

# PostgreSQL EC2 Setup Script for AWS CloudShell
# This script creates an EC2 instance with PostgreSQL ready to install

set -e  # Exit on any error

echo "🚀 Starting PostgreSQL EC2 Setup..."

# Configuration variables
INSTANCE_NAME="mashoor-postgres-db"
KEY_PAIR_NAME="mashoor-database"
INSTANCE_TYPE="t3.micro"
VOLUME_SIZE=30
REGION=$(aws configure get region || echo "us-east-1")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Using region: $REGION${NC}"

# Get your public IP for security group
echo "🔍 Getting your public IP..."
MY_IP=$(curl -s https://checkip.amazonaws.com)
echo -e "${GREEN}Your public IP: $MY_IP${NC}"

# Get the latest Amazon Linux 2023 AMI ID
echo "🔍 Finding latest Amazon Linux 2023 AMI..."
AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-*-x86_64" \
              "Name=state,Values=available" \
    --query 'Images|sort_by(@, &CreationDate)|[-1].ImageId' \
    --output text)

echo -e "${GREEN}Using AMI: $AMI_ID${NC}"

# Get default VPC and subnet
echo "🔍 Getting default VPC and subnet..."
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=is-default,Values=true" --query 'Vpcs[0].VpcId' --output text)
SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[0].SubnetId' --output text)

echo -e "${GREEN}VPC ID: $VPC_ID${NC}"
echo -e "${GREEN}Subnet ID: $SUBNET_ID${NC}"

# Create key pair if it doesn't exist
echo "🔑 Checking/Creating key pair..."
if aws ec2 describe-key-pairs --key-names $KEY_PAIR_NAME &>/dev/null; then
    echo -e "${YELLOW}Key pair $KEY_PAIR_NAME already exists${NC}"
else
    echo "Creating new key pair..."
    aws ec2 create-key-pair --key-name $KEY_PAIR_NAME --query 'KeyMaterial' --output text > ~/${KEY_PAIR_NAME}.pem
    chmod 400 ~/${KEY_PAIR_NAME}.pem
    echo -e "${GREEN}Key pair created and saved to ~/${KEY_PAIR_NAME}.pem${NC}"
fi

# Create security group
echo "🛡️  Creating security group..."
SG_NAME="postgres-db-sg"
SG_DESCRIPTION="Security group for PostgreSQL database server"

# Check if security group exists
if aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -q "sg-"; then
    SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" --query 'SecurityGroups[0].GroupId' --output text)
    echo -e "${YELLOW}Security group $SG_NAME already exists: $SECURITY_GROUP_ID${NC}"
else
    SECURITY_GROUP_ID=$(aws ec2 create-security-group \
        --group-name $SG_NAME \
        --description "$SG_DESCRIPTION" \
        --vpc-id $VPC_ID \
        --query 'GroupId' \
        --output text)
    
    echo -e "${GREEN}Created security group: $SECURITY_GROUP_ID${NC}"
    
    # Add SSH rule (port 22) for your IP only
    aws ec2 authorize-security-group-ingress \
        --group-id $SECURITY_GROUP_ID \
        --protocol tcp \
        --port 22 \
        --cidr ${MY_IP}/32 \
        --source-description "SSH access from my IP"
    
    # Add PostgreSQL rule (port 5432) for your IP only
    aws ec2 authorize-security-group-ingress \
        --group-id $SECURITY_GROUP_ID \
        --protocol tcp \
        --port 5432 \
        --cidr ${MY_IP}/32 \
        --source-description "PostgreSQL access from my IP"
    
    echo -e "${GREEN}Security group rules added for SSH (22) and PostgreSQL (5432)${NC}"
fi

# Create user data script for PostgreSQL installation
USER_DATA=$(cat << 'EOF'
#!/bin/bash
yum update -y
yum install -y postgresql15-server postgresql15-contrib htop

# Initialize PostgreSQL
postgresql-setup --initdb

# Start and enable PostgreSQL
systemctl start postgresql
systemctl enable postgresql

# Create a log file for our setup
touch /var/log/postgres-setup.log
echo "PostgreSQL installation completed at $(date)" >> /var/log/postgres-setup.log

# Create a setup script for the user
cat > /home/ec2-user/configure-postgres.sh << 'SETUP_SCRIPT'
#!/bin/bash
echo "🐘 PostgreSQL Configuration Script"
echo "=================================="

# Become postgres user and set password
sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'postgres123';"

# Create application user
sudo -u postgres createuser --interactive --pwprompt appuser

# Create application database
sudo -u postgres createdb -O appuser myapp_db

# Configure PostgreSQL for remote connections
sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /var/lib/pgsql/data/postgresql.conf

# Update pg_hba.conf for authentication
echo "host    all             all             0.0.0.0/0               md5" | sudo tee -a /var/lib/pgsql/data/pg_hba.conf

# Restart PostgreSQL
sudo systemctl restart postgresql

echo "✅ PostgreSQL configuration complete!"
echo "📝 Connection details:"
echo "   Host: $(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)"
echo "   Port: 5432"
echo "   Database: myapp_db"
echo "   Username: appuser"
echo ""
echo "🔐 To connect from your local machine:"
echo "   psql -h $(curl -s http://169.254.169.254/latest/meta-data/public-ipv4) -p 5432 -U appuser -d myapp_db"
SETUP_SCRIPT

chmod +x /home/ec2-user/configure-postgres.sh
chown ec2-user:ec2-user /home/ec2-user/configure-postgres.sh

echo "Setup script created at /home/ec2-user/configure-postgres.sh" >> /var/log/postgres-setup.log
EOF
)

# Launch EC2 instance
echo "🚀 Launching EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --count 1 \
    --instance-type $INSTANCE_TYPE \
    --key-name $KEY_PAIR_NAME \
    --security-group-ids $SECURITY_GROUP_ID \
    --subnet-id $SUBNET_ID \
    --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":$VOLUME_SIZE,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
    --user-data "$USER_DATA" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

echo -e "${GREEN}Instance launched: $INSTANCE_ID${NC}"

# Wait for instance to be running
echo "⏳ Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

# Get instance public IP
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

echo ""
echo "🎉 SUCCESS! Your PostgreSQL EC2 instance is ready!"
echo "=================================================="
echo -e "${GREEN}Instance ID: $INSTANCE_ID${NC}"
echo -e "${GREEN}Public IP: $PUBLIC_IP${NC}"
echo -e "${GREEN}Key file location: ~/${KEY_PAIR_NAME}.pem${NC}"
echo ""
echo "📋 Next Steps:"
echo "1. Wait 2-3 minutes for the instance to fully initialize"
echo "2. Connect via SSH:"
echo -e "   ${BLUE}ssh -i ~/${KEY_PAIR_NAME}.pem ec2-user@${PUBLIC_IP}${NC}"
echo ""
echo "3. Once connected, run the PostgreSQL configuration:"
echo -e "   ${BLUE}./configure-postgres.sh${NC}"
echo ""
echo "4. Test your database connection:"
echo -e "   ${BLUE}psql -h localhost -U appuser -d myapp_db${NC}"
echo ""
echo "🔐 Security Group allows access from your IP: $MY_IP"
echo "💾 Storage: ${VOLUME_SIZE}GB GP3 volume"
echo ""
echo "✨ Happy coding with PostgreSQL! ✨"