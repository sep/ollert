require 'sinatra'
require 'haml'
require 'sass'
require 'trello'
require 'json'
require 'rack-flash'
require 'sequel'
require 'rack/ssl'

require_relative 'helpers/ollert_helpers'

class Ollert < Sinatra::Base
  include OllertHelpers

  configure do
    if ENV['RACK_ENV'] == 'development'
      require 'sinatra/reloader'
      register Sinatra::Reloader
    end

    Sequel.connect ENV['DATABASE_URL']

    require_relative 'models/user'
  end

  use Rack::Session::Cookie, secret: ENV['SESSION_SECRET'], expire_after: 30 * (60*60*24) # 30 days in seconds
  use Rack::Flash, sweep: true
  use Rack::SSL, :exclude => ->(_){ ENV['RACK_ENV'] != "production" }

  set(:auth) do |role|
    condition do
      @user = get_user
      if role == :authenticated
        if @user.nil?
          session[:user] = nil
          flash[:warning] = "Hey! You should log in to do that action."
          redirect '/'
        end
      elsif role == :token
        if session[:token].nil? || session[:token].empty?
          flash[:info] = "Connect with Trello to analyze your boards."
          redirect '/'
        end
      end
    end
  end

  get '/', :auth => :none do
    if !@user.nil? && !@user.member_token.nil?
      redirect '/boards'
    end
    
    haml_view_model :landing, @user
  end

  get '/boards', :auth => :none do
    if !@user.nil? && !@user.member_token.nil?
      session[:token] = @user.member_token
    elsif !params[:token].nil? && !params[:token].empty?
      session[:token] = params[:token]
    else
      flash[:info] = "Connect with Trello to analyze your boards."
      redirect '/'
    end

    token, client = get_trello_object session[:token], :token, session[:token], nil, @user
    member = token.member

    # this logic needs to be fixed - why does this belong here?
    unless @user.nil?
      @user.member_token = session[:token]
      @user.trello_name = member.attributes[:username]
      @user.save
    end
    
    # change this to be async
    @boards = get_user_boards member

    haml_view_model :boards, @user
  end

  get '/boards/:id', :auth => :token do |board_id|
    # this call should be able to be pared down to just a call to get the boards
    token, @client = get_trello_object session[:token], :token, session[:token], nil, @user
    @boards = get_user_boards token.member

    @board_name = @boards.values.flatten.select {|x| x.id == board_id}.first.attributes[:name]
    @board_id = board_id

    haml_view_model :analysis, @user
  end
  
   get '/boards/:id/data' do |board_id|
    @board, _ = get_trello_object session[:token], :board, board_id, @client, @user

    @wip_data = Hash.new
    options = {limit: 999}
    cards = @board.cards options
    lists = @board.lists(filter: :all)
    actions = @board.actions options
    
    cards.group_by { |x| x.list.name }.each_pair do |k,v|
      @wip_data[k] = v.count
    end

    data = { wipcategories: @wip_data.keys, wipdata: @wip_data.values }
    
    data.to_json
  end

  get '/boards/:id/cfd' do |board_id|
    board, _ = get_trello_object session[:token], :board, board_id, @client, @user

    # might be faster to just get lists and actions without getting the board
    lists = board.lists(filter: :all)
    actions = board.actions(limit: 999)
    closed_lists = Hash.new
    lists.select {|l| l.closed}.each do |l|
      closed_lists[l.id] = l.actions.first.date
    end

    list_ids_to_names = Hash.new
    lists.each do |list|
      list_ids_to_names[list.id] = list.name
    end

    cfd_data = get_cfd_data(actions, list_ids_to_names, closed_lists)
    dates = cfd_data.keys.sort
    cfd_values = Array.new
    lists.collect(&:name).uniq.each do |list|
      list_array = Array.new
      dates.each do |date|
        list_array << cfd_data[date][list]
      end
      cfd_values << { name: list, data: list_array}
    end

    dates.map! {|date| date.strftime("%b %-d")}

    data = { dates: dates, cfddata: cfd_values}

    data.to_json
  end
  
  get '/boards/:id/stats' do |board_id|
    board, _ = get_trello_object session[:token], :board, board_id, @client, @user
    @stats = get_stats(board)
    @stats.to_json
  end
  
  get '/boards/:id/labelcounts' do |board_id|
    @board, _ = get_trello_object session[:token], :board, board_id, @client, @user
    @label_count_data = get_label_count_data(@board.cards)
    @label_count_data.to_json
  end

  get '/signup' do
    haml_view_model :signup, @user
  end

  post '/signup' do
    msg = validate_signup(params)
    if msg.empty?
      user = User.new
      user.email = params[:email]
      user.password = params[:password]

      if user.save
        session[:user] = user.id
        flash[:success] = "You're signed up! Click below to connect with Trello for the first time."
        redirect '/'
      else
        flash[:error] = "Something's broken, please try again later."
        @email = params[:email]
        haml_view_model :signup
      end
    else
      flash[:error] = msg
      @email = params[:email]
      haml_view_model :signup
    end
  end

  get '/login' do
    haml_view_model :login
  end

  post '/logout', :auth => :authenticated do
    session[:user] = nil
    session[:token] = nil
    flash[:success] = "Come see us again soon!"

    redirect '/'
  end

  get '/settings/trello/disconnect', :auth => :authenticated do
    @user.member_token = nil
    @user.trello_name = nil

    if !@user.save
      flash[:error] = "I couldn't quite disconnect you from Trello. Do you mind trying again?"
    else
      flash[:success] = "Disconnected from Trello."
    end

    redirect '/settings'
  end

  post '/settings/email', :auth => :authenticated do
    msg = validate_email params[:email]
    if msg.empty?
      @user.email = params[:email]

      if @user.save
        flash[:success] = "Your new email is #{@user.email}. Use this to log in!"
      else
        flash[:error] = "I couldn't quite update your email. Do you mind trying again?"
      end
    else
      flash[:error] = msg
    end

    redirect '/settings'
  end

  post '/settings/password', :auth => :authenticated do
    current_pw = params[:current_password]
    new_password = params[:new_password]
    confirm_password = params[:confirm_password]

    if current_pw.nil_or_empty?
      flash[:error] = "Enter your old password so I know it's really you."
      redirect '/settings'
    end

    if !@user.authenticate? current_pw
      flash[:error] = "The current password entered is incorrect. Try again."
      redirect '/settings'
    end

    if new_password.nil_or_empty?
      flash[:error] = "New password must be at least 1 character in length."
      redirect '/settings'
    end

    if new_password != confirm_password
      flash[:error] = "Could not confirm new password. Type more carefully."
      redirect '/settings'
    end

    @user.password = new_password
    if !@user.save
      flash[:error] = "Password could not be changed. Do you mind trying again?"
      redirect '/settings'
    end

    flash[:success] = "Password has been changed."
    redirect '/settings'
  end

  get '/settings/trello/connect', :auth => :authenticated do
    session[:token] = params[:token]

    client = get_client ENV['PUBLIC_KEY'], session[:token]

    token = client.find(:token, session[:token])
    member = token.member

    @user.member_token = session[:token]
    @user.trello_name = member.attributes[:username]

    if !@user.save
      flash[:error] = "I couldn't quite connect you to Trello. Do you mind trying again?"
    else
      flash[:success] = "Connected you to the Trello user #{@user.trello_name}"
    end

    redirect '/settings'
  end

  post '/authenticate' do
    user = User.find email: params['email']
    if user.nil?
      flash[:warning] = "Email address #{params['email_address']} does not appear to be registered."
      redirect :login
    elsif !user.authenticate? params['password']
      flash[:warning] = "I didn't find that username/password combination. Check your spelling."
      redirect :login
    else
      flash[:success] = "Welcome back."
      session[:user] = user.id
      redirect '/'
    end
  end

  post '/settings/delete', :auth => :authenticated do
    if params[:iamsure] == "on"
      email = @user.email

      session[:user] = nil
      session[:token] = nil
      if @user.delete
        flash[:success] = "User with login of #{email} has been deleted. Come back and sign up again one day!"
        redirect '/'
      else
        flash[:error] = "I wasn't able to delete that user. Do you mind trying again?"
        redirect '/settings'
      end
    else
      flash[:warning] = "You must check the 'I am sure' checkbox to delete your account."
      redirect '/settings'
    end
  end

  get '/settings', :auth => :authenticated do
    haml_view_model :settings, @user
  end

  get '/privacy', :auth => :none do
    haml_view_model :privacy, @user
  end

  get '/terms', :auth => :none do
    haml_view_model :terms, @user
  end

  get '/styles.css' do
    scss :styles
  end
end
