class AuthController < ApplicationController
  skip_before_action :verify_authenticity_token, only: [:sign_in, :sign_out]

  def sign_in
    if params[:jwt].blank? || params[:provider].blank?
      render json: {success: false, error: "Missing jwt or provider parameter"}, status: :unauthorized
      return
    end
    result = AuthenticationService.call(
      auth_token: params[:jwt],
      provider: params[:provider]
    )

    if result[:success]
      session[:user_id] = result[:user].id
      session[:provider] = params[:provider]

      render json: {
        success: true,
        user: {
          id: result[:user].id,
          email: result[:user].email,
          name: result[:user].name,
          provider: params[:provider]
        }
      }
    else
      render json: {
        success: false,
        error: result[:error]
      }, status: :unauthorized
    end
  rescue => e
    Rails.logger.error "Authentication error: #{e.message}"
    render json: {
      success: false,
      error: "Authentication failed"
    }, status: :internal_server_error
  end

  def sign_out
    session[:user_id] = nil
    session[:provider] = nil

    render json: {success: true}
  end
end
