$: << 'lib'

require 'rubygems'
require 'capybara'
require 'capybara/dsl'
require 'rack/test'
require 'minitest/autorun'
require 'minitest/hooks/default'

require 'roda'
require 'sequel'
require 'bcrypt'
require 'logger'
require 'tilt/string'

DB = Sequel.postgres(:user=>'rodauth_test')
#DB.loggers << Logger.new($stdout)

class Account < Sequel::Model
  plugin :validation_helpers

  def set_password(password)
    hash = BCrypt::Password.create(password, :cost=>BCrypt::Engine::MIN_COST)
    if DB[:account_password_hashes].where(:id=>id).update(:password_hash=>hash) == 0
      DB[:account_password_hashes].insert(:id=>id, :password_hash=>hash)
    end
  end

  def validate
    super
    validates_unique(:email){|ds| ds.where(:status_id=>[1,2])} unless status_id == 3
  end
end

Base = Class.new(Roda)
Base.plugin :render, :layout=>false
Base.plugin(:not_found){raise "path #{request.path_info} not found"}
Base.use Rack::Session::Cookie, :secret=>'0123456789'

class Minitest::HooksSpec
  include Rack::Test::Methods
  include Capybara::DSL

  attr_reader :app

  def app=(app)
    @app = Capybara.app = app
  end

  def rodauth(&block)
    @rodauth_block = block
  end

  def roda(&block)
    app = Class.new(Base)
    app.plugin(:rodauth, &@rodauth_block)
    app.route(&block)
    self.app = app
  end

  around do |&block|
    DB.transaction(:rollback=>:always, :savepoint=>true, :auto_savepoint=>true){super(&block)}
  end
  
  around(:all) do |&block|
    DB.transaction(:rollback=>:always){super(&block)}
  end
  
  after do
    Capybara.reset_sessions!
    Capybara.use_default_driver
  end
end

describe 'Rodauth' do
  before(:all) do
    Account.create(:email=>'foo@example.com', :status_id=>2).set_password('0123456789')
  end

  it "should handle logins and logouts" do
    rodauth{enable :login, :logout}
    roda do |r|
      r.rodauth
      next unless session[:account_id]
      r.root{"Logged In"}
    end

    visit '/login'

    fill_in 'Login', :with=>'foo@example2.com'
    fill_in 'Password', :with=>'0123456789'
    click_button 'Login'
    page.html.must_match(/no matching login/)

    fill_in 'Login', :with=>'foo@example.com'
    fill_in 'Password', :with=>'012345678'
    click_button 'Login'
    page.html.must_match(/invalid password/)

    fill_in 'Login', :with=>'foo@example.com'
    fill_in 'Password', :with=>'0123456789'
    click_button 'Login'
    page.current_path.must_equal '/'
    page.html.must_match(/Logged In/)

    visit '/logout'
    click_button 'Logout'
    page.current_path.must_equal '/login'
  end

  it "should handle overriding login action" do
    rodauth do
      enable :login
      login_post_block do |r|
        if r['login'] == 'apple' && r['password'] == 'banana'
          session[:user_id] = 'pear'
          r.redirect '/'
        end
        r.redirect '/login'
      end
    end
    roda do |r|
      r.rodauth
      next unless session[:user_id] == 'pear'
      r.root{"Logged In"}
    end

    visit '/login'

    fill_in 'Login', :with=>'appl'
    fill_in 'Password', :with=>'banana'
    click_button 'Login'
    page.html.wont_match(/Logged In/)

    fill_in 'Login', :with=>'apple'
    fill_in 'Password', :with=>'banan'
    click_button 'Login'
    page.html.wont_match(/Logged In/)

    fill_in 'Login', :with=>'apple'
    fill_in 'Password', :with=>'banana'
    click_button 'Login'
    page.current_path.must_equal '/'
    page.html.must_match(/Logged In/)
  end

  it "should handle overriding some login attributes" do
    rodauth do
      enable :login
      account_from_login do |login|
        Account.first if login == 'apple'
      end
      password_match? do |password|
        password == 'banana'
      end
      update_session do
        session[:user_id] = 'pear'
      end
      no_matching_login_message "no user"
      invalid_password_message "bad password"
    end
    roda do |r|
      r.rodauth
      next unless session[:user_id] == 'pear'
      r.root{"Logged In"}
    end

    visit '/login'

    fill_in 'Login', :with=>'appl'
    fill_in 'Password', :with=>'banana'
    click_button 'Login'
    page.html.must_match(/no user/)

    fill_in 'Login', :with=>'apple'
    fill_in 'Password', :with=>'banan'
    click_button 'Login'
    page.html.must_match(/bad password/)

    fill_in 'Login', :with=>'apple'
    fill_in 'Password', :with=>'banana'
    click_button 'Login'
    page.current_path.must_equal '/'
    page.html.must_match(/Logged In/)
  end

  it "should handle a prefix and some other login options" do
    rodauth do
      enable :login, :logout
      prefix 'auth'
      session_key :login_email
      session_value{account.email}
      login_param{request['lp']}
      password_param 'p'
      login_redirect{"/foo/#{account.email}"}
      logout_redirect '/auth/lin'
      login_route 'lin'
      logout_route 'lout'
    end
    roda do |r|
      r.on 'auth' do
        r.rodauth
      end
      next unless session[:login_email] =~ /example/
      r.get('foo/:email'){|e| "Logged In: #{e}"}
    end
    app.plugin :render, :views=>'spec/views', :engine=>'str'

    visit '/auth/lin?lp=l'

    fill_in 'Login', :with=>'foo@example2.com'
    fill_in 'Password', :with=>'0123456789'
    click_button 'Login'
    page.html.must_match(/no matching login/)

    fill_in 'Login', :with=>'foo@example.com'
    fill_in 'Password', :with=>'012345678'
    click_button 'Login'
    page.html.must_match(/invalid password/)

    fill_in 'Login', :with=>'foo@example.com'
    fill_in 'Password', :with=>'0123456789'
    click_button 'Login'
    page.current_path.must_equal '/foo/foo@example.com'
    page.html.must_match(/Logged In: foo@example\.com/)

    visit '/auth/lout'
    click_button 'Logout'
    page.current_path.must_equal '/auth/lin'
  end

  it "should support closing accounts" do
    rodauth do
      enable :login, :close_account
    end
    roda do |r|
      r.rodauth
      r.root{""}
    end

    visit '/login'
    fill_in 'Login', :with=>'foo@example.com'
    fill_in 'Password', :with=>'0123456789'
    click_button 'Login'
    page.current_path.must_equal '/'

    visit '/close-account'
    click_button 'Close Account'
    page.current_path.must_equal '/'

    Account.select_map(:status_id).must_equal [3]
  end

  it "should support closing accounts with overrides" do
    rodauth do
      enable :login, :close_account
      close_account do
        account.email = 'foo@bar.com'
        super()
      end
      close_account_route 'close'
      close_account_redirect '/login'
    end
    roda do |r|
      r.rodauth
      r.root{""}
    end

    visit '/login'
    fill_in 'Login', :with=>'foo@example.com'
    fill_in 'Password', :with=>'0123456789'
    click_button 'Login'
    page.current_path.must_equal '/'

    visit '/close'
    click_button 'Close Account'
    page.current_path.must_equal '/login'

    Account.select_map(:status_id).must_equal [3]
    Account.select_map(:email).must_equal ['foo@bar.com']
  end

  it "should support creating accounts" do
    rodauth do
      enable :login, :create_account
    end
    roda do |r|
      r.rodauth
      r.root{""}
    end

    visit '/create-account'
    fill_in 'Login', :with=>'foo@example.com'
    fill_in 'Password', :with=>'0123456789'
    fill_in 'Confirm Password', :with=>'0123456789'
    click_button 'Create Account'
    page.html.must_match(/is already taken/)
    page.current_path.must_equal '/create-account'

    visit '/create-account'
    fill_in 'Login', :with=>'foo@example2.com'
    fill_in 'Password', :with=>'0123456789'
    fill_in 'Confirm Password', :with=>'012345678'
    click_button 'Create Account'
    page.html.must_match(/passwords do not match/)
    page.current_path.must_equal '/create-account'

    visit '/create-account'
    fill_in 'Login', :with=>'foo@example2.com'
    fill_in 'Password', :with=>'0123456789'
    fill_in 'Confirm Password', :with=>'0123456789'
    click_button 'Create Account'
    page.current_path.must_equal '/'

    visit '/login'
    fill_in 'Login', :with=>'foo@example2.com'
    fill_in 'Password', :with=>'0123456789'
    click_button 'Login'
    page.current_path.must_equal '/'
  end

  it "should support changing passwords for accounts" do
    rodauth do
      enable :login, :logout, :change_password
    end
    roda do |r|
      r.rodauth
      r.root{""}
    end

    visit '/login'
    fill_in 'Login', :with=>'foo@example.com'
    fill_in 'Password', :with=>'0123456789'
    click_button 'Login'
    page.current_path.must_equal '/'

    visit '/change-password'
    fill_in 'Password', :with=>'0123456'
    fill_in 'Confirm Password', :with=>'0123456789'
    click_button 'Change Password'
    page.html.must_match(/passwords do not match/)
    page.current_path.must_equal '/change-password'

    fill_in 'Password', :with=>'0123456'
    fill_in 'Confirm Password', :with=>'0123456'
    click_button 'Change Password'
    page.current_path.must_equal '/'

    visit '/logout'
    click_button 'Logout'

    visit '/login'
    fill_in 'Login', :with=>'foo@example.com'
    fill_in 'Password', :with=>'0123456789'
    click_button 'Login'
    page.html.must_match(/invalid password/)
    page.current_path.must_equal '/login'

    fill_in 'Login', :with=>'foo@example.com'
    fill_in 'Password', :with=>'0123456'
    click_button 'Login'
    page.current_path.must_equal '/'
  end
end