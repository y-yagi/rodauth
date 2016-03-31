require File.expand_path("spec_helper", File.dirname(__FILE__))

describe 'Rodauth account expiration feature' do
  it "should force account expiration after x number of days" do
    rodauth do
      enable :login, :logout, :single_session
    end
    roda do |r|
      rodauth.check_single_session
      r.rodauth
      r.is("clear"){session.delete(:single_session_key); DB[:account_session_keys].delete; r.redirect '/'}
      r.root{view :content=>rodauth.logged_in? ? "Logged In" : "Not Logged"}
    end

    visit '/login'
    fill_in 'Login', :with=>'foo@example.com'
    fill_in 'Password', :with=>'0123456789'
    click_button 'Login'
    page.body.must_include "Logged In"

    session1 = get_cookie('rack.session')

    visit '/logout'
    click_button 'Logout'

    visit '/'
    page.body.must_include "Not Logged"

    remove_cookie('rack.session')
    set_cookie('rack.session', session1)
    visit '/foo'
    page.current_path.must_equal '/'
    page.body.must_include "Not Logged"
    page.find('#notice_flash').text.must_equal "This session has been logged out as another session has become active"

    visit '/login'
    fill_in 'Login', :with=>'foo@example.com'
    fill_in 'Password', :with=>'0123456789'
    click_button 'Login'
    page.body.must_include "Logged In"

    session2 = get_cookie('rack.session')
    remove_cookie('rack.session')
    set_cookie('rack.session', session1)
    visit '/'
    page.body.must_include "Not Logged"
    page.find('#notice_flash').text.must_equal "This session has been logged out as another session has become active"

    remove_cookie('rack.session')
    set_cookie('rack.session', session2)
    visit '/'
    page.body.must_include "Logged In"

    visit '/clear'
    page.current_path.must_equal '/'
    page.body.must_include "Logged In"
  end
end