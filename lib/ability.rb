# frozen_string_literal: true

class Ability
  include CanCan::Ability

  # StevensED: role-based permissions. Admin (and API integration users) keep upstream's full access.
  def initialize(user)
    return unless user

    case user.role
    when User::EDITOR_ROLE then editor_abilities(user)
    when User::VIEWER_ROLE then viewer_abilities(user)
    when User::CLIENT_ROLE then client_abilities(user)
    else admin_abilities(user)
    end
  end

  def editor_abilities(user)
    can %i[read create update], Template, Abilities::TemplateConditions.collection(user) do |template|
      Abilities::TemplateConditions.entity(template, user:, ability: 'manage')
    end
    can :destroy, Template, account_id: user.account_id
    can :manage, TemplateFolder, account_id: user.account_id
    can :manage, TemplateSharing, template: { account_id: user.account_id }
    can :manage, Submission, account_id: user.account_id
    can :manage, Submitter, account_id: user.account_id
    can :read, User, account_id: user.account_id
    can :manage, User, id: user.id
    can :read, Account, id: user.account_id
    can :read, AccountConfig, account_id: user.account_id
    personal_abilities(user)
    can :manage, :email_reminders
    can :manage, :bulk_send
  end

  def viewer_abilities(user)
    can :read, Template, Abilities::TemplateConditions.collection(user) do |template|
      Abilities::TemplateConditions.entity(template, user:, ability: 'read')
    end
    can :read, TemplateFolder, account_id: user.account_id
    can :read, Submission, account_id: user.account_id
    can :read, Submitter, account_id: user.account_id
    can :read, Account, id: user.account_id
    can :manage, User, id: user.id
    personal_abilities(user)
  end

  def client_abilities(user)
    can :read, Submitter, account_id: user.account_id, email: user.email
    can :manage, EncryptedUserConfig, user_id: user.id
    can :manage, UserConfig, user_id: user.id
  end

  def personal_abilities(user)
    can :manage, EncryptedUserConfig, user_id: user.id
    can :manage, UserConfig, user_id: user.id
    can :manage, AccessToken, user_id: user.id
  end

  def admin_abilities(user)
    can %i[read create update], Template, Abilities::TemplateConditions.collection(user) do |template|
      Abilities::TemplateConditions.entity(template, user:, ability: 'manage')
    end

    can :destroy, Template, account_id: user.account_id
    can :manage, TemplateFolder, account_id: user.account_id
    can :manage, TemplateSharing, template: { account_id: user.account_id }
    can :manage, Submission, account_id: user.account_id
    can :manage, Submitter, account_id: user.account_id
    can :manage, User, account_id: user.account_id
    can :manage, EncryptedConfig, account_id: user.account_id
    can :manage, EncryptedUserConfig, user_id: user.id
    can :manage, AccountConfig, account_id: user.account_id
    can :manage, UserConfig, user_id: user.id
    can :manage, Account, id: user.account_id
    can :manage, AccessToken, user_id: user.id
    can :manage, McpToken, user_id: user.id
    can :manage, WebhookUrl, account_id: user.account_id

    can :manage, :mcp

    # StevensED: features built in this fork (Pro placeholders in upstream).
    can :manage, :email_reminders
    can :manage, :custom_logo
    can :manage, :bulk_send
  end
end
