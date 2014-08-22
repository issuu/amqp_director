{logdir, "test_logs"}.
%{cover, "amqp_director.cover"}.
{config, "test-local.config"}.
{alias, test, "test"}.
%% Select suites to run
{suites, test, [main_SUITE]}.
%{cases, test, integration_SUITE, [insight_test_stats_for_creator]}.
%{cases, test, integration_SUITE, [insight_test_stats_for_doc]}.
%{cases, test, integration_SUITE, [insight_test_docs_for_creator]}.
%{cases, test, integration_SUITE, [insight_test_lifetime_doc_impressions]}.
%{cases, test, integration_SUITE, [insight_test_lifetime_docs_impressions]}.
% {cases, test, integration_SUITE, [insight_test_lifetime_doc_impressions_reads]}.
%{cases, test, integration_SUITE, [insight_validate_parameters]}.
