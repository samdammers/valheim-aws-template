# --- EC2 Instance Role ---
# SSM for admin shell access (no SSH), plus read access to the server password secret.
resource "aws_iam_role" "ec2" {
  name = "valheim-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "ec2_secrets" {
  name = "valheim-secrets-access"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.valheim.arn
    }]
  })
}

resource "aws_iam_instance_profile" "valheim" {
  name = "valheim-ec2-profile"
  role = aws_iam_role.ec2.name
}

# --- Lambda Execution Role ---
resource "aws_iam_role" "lambda" {
  name = "valheim-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_permissions" {
  name = "valheim-lambda-permissions"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:StartInstances", "ec2:StopInstances"]
        Resource = "arn:aws:ec2:${local.region}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.valheim.id}"
      },
      {
        # DescribeInstances does not support resource-level restriction.
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "cloudwatch:GetMetricStatistics"
        Resource = "*"
      },
      {
        # Discord slash-command responses (only, never the plain HTTP routes) include
        # the server password so friends can see how to connect without asking.
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = aws_secretsmanager_secret.valheim.arn
      },
    ]
  })
}

# --- API Gateway account-level CloudWatch logging role ---
# This is a singleton PER AWS ACCOUNT/REGION, not per-API - aws_api_gateway_account
# sets it account-wide, so declaring it here will conflict with any other Terraform
# stack in the same account that already manages it. If that's your situation, set
# manage_api_gateway_account = false in your .envrc and configure it in whichever
# stack already owns it instead - without it (from *some* stack), enabling
# access_log_settings on the API Gateway stage in apigateway.tf will fail to apply.
resource "aws_iam_role" "apigw_cloudwatch" {
  count = var.manage_api_gateway_account ? 1 : 0
  name  = "valheim-apigw-cloudwatch-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "apigateway.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "apigw_cloudwatch" {
  count      = var.manage_api_gateway_account ? 1 : 0
  role       = aws_iam_role.apigw_cloudwatch[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "this" {
  count               = var.manage_api_gateway_account ? 1 : 0
  cloudwatch_role_arn = aws_iam_role.apigw_cloudwatch[0].arn
}
