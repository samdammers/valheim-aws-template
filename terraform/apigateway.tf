resource "aws_api_gateway_rest_api" "valheim" {
  name        = "Valheim-API"
  description = "Valheim server management API"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = local.tags
}

# /start
resource "aws_api_gateway_resource" "start" {
  rest_api_id = aws_api_gateway_rest_api.valheim.id
  parent_id   = aws_api_gateway_rest_api.valheim.root_resource_id
  path_part   = "start"
}
resource "aws_api_gateway_method" "start" {
  rest_api_id   = aws_api_gateway_rest_api.valheim.id
  resource_id   = aws_api_gateway_resource.start.id
  http_method   = "GET"
  authorization = "NONE"
}
resource "aws_api_gateway_integration" "start" {
  rest_api_id             = aws_api_gateway_rest_api.valheim.id
  resource_id             = aws_api_gateway_resource.start.id
  http_method             = aws_api_gateway_method.start.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.valheim.invoke_arn
  timeout_milliseconds    = 15000
}

# /stop
resource "aws_api_gateway_resource" "stop" {
  rest_api_id = aws_api_gateway_rest_api.valheim.id
  parent_id   = aws_api_gateway_rest_api.valheim.root_resource_id
  path_part   = "stop"
}
resource "aws_api_gateway_method" "stop" {
  rest_api_id   = aws_api_gateway_rest_api.valheim.id
  resource_id   = aws_api_gateway_resource.stop.id
  http_method   = "GET"
  authorization = "NONE"
}
resource "aws_api_gateway_integration" "stop" {
  rest_api_id             = aws_api_gateway_rest_api.valheim.id
  resource_id             = aws_api_gateway_resource.stop.id
  http_method             = aws_api_gateway_method.stop.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.valheim.invoke_arn
  timeout_milliseconds    = 15000
}

# /status
resource "aws_api_gateway_resource" "status" {
  rest_api_id = aws_api_gateway_rest_api.valheim.id
  parent_id   = aws_api_gateway_rest_api.valheim.root_resource_id
  path_part   = "status"
}
resource "aws_api_gateway_method" "status" {
  rest_api_id   = aws_api_gateway_rest_api.valheim.id
  resource_id   = aws_api_gateway_resource.status.id
  http_method   = "GET"
  authorization = "NONE"
}
resource "aws_api_gateway_integration" "status" {
  rest_api_id             = aws_api_gateway_rest_api.valheim.id
  resource_id             = aws_api_gateway_resource.status.id
  http_method             = aws_api_gateway_method.status.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.valheim.invoke_arn
  timeout_milliseconds    = 15000
}

# /discord - Discord Interactions Endpoint (slash commands). Authorization is "NONE"
# at the AWS layer deliberately: Discord's servers call this directly (no IP to
# allowlist), and the Lambda verifies Discord's own Ed25519 request signature instead.
resource "aws_api_gateway_resource" "discord" {
  rest_api_id = aws_api_gateway_rest_api.valheim.id
  parent_id   = aws_api_gateway_rest_api.valheim.root_resource_id
  path_part   = "discord"
}
resource "aws_api_gateway_method" "discord" {
  rest_api_id   = aws_api_gateway_rest_api.valheim.id
  resource_id   = aws_api_gateway_resource.discord.id
  http_method   = "POST"
  authorization = "NONE"
}
resource "aws_api_gateway_integration" "discord" {
  rest_api_id             = aws_api_gateway_rest_api.valheim.id
  resource_id             = aws_api_gateway_resource.discord.id
  http_method             = aws_api_gateway_method.discord.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.valheim.invoke_arn
  timeout_milliseconds    = 15000
}

# Deployment - recreated automatically when any integration changes
resource "aws_api_gateway_deployment" "valheim" {
  rest_api_id = aws_api_gateway_rest_api.valheim.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_integration.start,
      aws_api_gateway_integration.stop,
      aws_api_gateway_integration.status,
      aws_api_gateway_integration.discord,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudwatch_log_group" "apigw" {
  name              = "/aws/apigateway/valheim"
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_api_gateway_stage" "valheim" {
  deployment_id = aws_api_gateway_deployment.valheim.id
  rest_api_id   = aws_api_gateway_rest_api.valheim.id
  stage_name    = "Prod"

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw.arn
    format = jsonencode({
      requestId       = "$context.requestId"
      requestTime     = "$context.requestTime"
      httpMethod      = "$context.httpMethod"
      path            = "$context.path"
      status          = "$context.status"
      responseLatency = "$context.responseLatency"
    })
  }

  tags = local.tags
}

resource "aws_api_gateway_method_settings" "valheim" {
  rest_api_id = aws_api_gateway_rest_api.valheim.id
  stage_name  = aws_api_gateway_stage.valheim.stage_name
  method_path = "*/*"

  settings {
    throttling_burst_limit = 5
    throttling_rate_limit  = 1
  }
}

resource "aws_api_gateway_domain_name" "valheim" {
  domain_name              = local.api_fqdn
  regional_certificate_arn = aws_acm_certificate_validation.api.certificate_arn
  security_policy          = "TLS_1_2"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = local.tags
}

resource "aws_api_gateway_base_path_mapping" "valheim" {
  api_id      = aws_api_gateway_rest_api.valheim.id
  stage_name  = aws_api_gateway_stage.valheim.stage_name
  domain_name = aws_api_gateway_domain_name.valheim.domain_name
}
